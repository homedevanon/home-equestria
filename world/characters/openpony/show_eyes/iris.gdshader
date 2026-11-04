shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Same curved surface as the sclera: no floating alpha cards or eye holes.
uniform sampler2D tint_mask : filter_linear_mipmap, repeat_disable;
// Both highlights share the same calibrated art/centres, independent of pupil size calibration.
uniform sampler2D shine_ink : source_color, filter_linear_mipmap, repeat_disable;
uniform vec4 iris_color : source_color = vec4(0.38,0.73,0.31,1.0);
uniform vec2 gaze_uv = vec2(0.0);
// Self-lit iris (the summoned Great Evil's white glare); 0 everywhere else.
uniform float glow = 0.0;
// dev 2026-09-25: iris 80 % of the open eye's height (20 % white left under it when its top
// touches the lid). Measured with open lids: the eye shows V 0.13-0.93 of the art (0.80 tall);
// the iris art is 0.946 tall, so 0.8 * 0.80 / 0.946 = 0.68. Scaled about the art's centre.
uniform float iris_scale = 0.68;
uniform vec2 iris_center = vec2(0.51, 0.5);
// The two original drawings have different bounds/centres. Sample each in a shared
// iris frame, so dilation and gaze cannot make one pupil smaller or lower.
uniform vec4 tint_source = vec4(0.51, 0.5, 1.0, 1.0);
// Exact ellipse fitted to each original vector pupil path after equalising its
// centre/extent. Highlights must not add black bumps to the pupil silhouette.
uniform vec3 pupil_metric = vec3(8.846705, 0.007479, 8.110767);
uniform float rest_convergence = 0.012;
// Cartoon squash and stretch of the iris, pupil and shines (dev 2026-11-02): (1, 1) as drawn; a
// squeezed eye takes a shorter, wider iris so its shines come down into what stays open.
uniform vec2 iris_shape = vec2(1.0);
uniform float pupil_dilation = 1.0;
uniform float heart_shines = 0.0;
uniform float shine_drop = 0.0;
// Measured centres of the two white highlights in each original iris artwork.
uniform vec4 shine_centers = vec4(0.647949, 0.271470, 0.495749, 0.442270);
// Undo surface stretching in head space, keeping gaze and the iris independent
// of the physically moving lids. CUSTOM0 stores this vertex's authored basis.
uniform mat4 eye_rest_from_pose = mat4(1.0);
uniform float iris_projection = 0.0;
varying vec2 iris_uv;

void vertex() {
	vec3 rest = (eye_rest_from_pose * vec4(VERTEX, 1.0)).xyz;
	vec3 change = rest - CUSTOM0.xyz;
	vec2 shift = vec2(-change.x * 0.7071067812 / 0.110, -change.y / 0.148);
	iris_uv = UV + shift * iris_projection;
}

// Show lids drawn on the eye (dev 2026-11-02, world/characters/openpony/show_lid.gd).
#include "res://world/characters/openpony/show_lid.gdshaderinc"
// +1 when this eye's nose side is toward +UV.x (the eye on the mesh's +x), -1 otherwise.
uniform float nose_sign = 1.0;
// The coat the drawn lid wears, as the head's cel material has it (fill, shade with its mix in a).
uniform vec4 lid_coat : source_color = vec4(0.6, 0.86, 0.96, 1.0);
uniform vec4 lid_coat_shade : source_color = vec4(0.0);
uniform vec4 lid_ink : source_color = vec4(0.018, 0.012, 0.025, 1.0);

// Cel lighting for the drawn lid, as the coat has it (addons/cel-shader).
#include "res://addons/cel-shader/includes/base-cel-shader.gdshaderinc"
varying float lid_mask;

float heart(vec2 p, vec2 center, vec2 radius) {
	vec2 q = (p - center) / radius;
	q.y = -q.y;
	float bounds = 1.0 - step(1.45, max(abs(q.x), abs(q.y)));
	q = clamp(q, vec2(-1.5), vec2(1.5));
	float a = dot(q, q) - 1.0;
	float field = a * a * a - q.x * q.x * q.y * q.y * q.y;
	vec2 gradient = vec2(6.0*q.x*a*a - 2.0*q.x*q.y*q.y*q.y,
		6.0*q.y*a*a - 3.0*q.x*q.x*q.y*q.y);
	float distance = field / max(length(gradient), 0.05);
	// Bound the footprint near a grazing triangle. Polynomial derivatives far
	// outside the heart used to create stray white streaks on the far eye.
	float aa = clamp(length(fwidth(q)) * 0.6, 0.002, 0.10);
	return (1.0 - smoothstep(-aa, aa, distance)) * bounds;
}

void fragment() {
	vec2 uv = (iris_uv - gaze_uv - vec2(nose_sign * rest_convergence, 0.0) - iris_center) / (iris_scale * iris_shape) + iris_center;
	vec2 tint_uv = (uv - iris_center) * tint_source.zw + tint_source.xy;
	vec4 tint = texture(tint_mask, tint_uv);
	vec2 pupil_uv = (uv - iris_center) / max(pupil_dilation, 0.15) + iris_center;
	vec2 q = pupil_uv - iris_center;
	float pupil_edge = pupil_metric.x*q.x*q.x + 2.0*pupil_metric.y*q.x*q.y + pupil_metric.z*q.y*q.y - 1.0;
	float pupil_aa = max(fwidth(pupil_edge), 0.001);
	float pupil = 1.0 - smoothstep(-pupil_aa, pupil_aa, pupil_edge);
	float inside = step(0.0,tint_uv.x)*step(tint_uv.x,1.0)*step(0.0,tint_uv.y)*step(tint_uv.y,1.0);
	vec3 color = mix(vec3(0.94), iris_color.rgb*tint.r+vec3(tint.g), tint.a*inside);
	color = mix(color, vec3(0.0035), pupil * tint.a * inside);
	vec2 shine_uv = pupil_uv - vec2(0.0, shine_drop);
	vec4 original_shine = texture(shine_ink, shine_uv - iris_center + vec2(0.528451, 0.476830));
	float shine = smoothstep(0.6, 0.9, original_shine.r) * original_shine.a;
	float hearts = max(heart(shine_uv, shine_centers.xy + vec2(0.0, 0.025), vec2(0.14, 0.105)),
		heart(shine_uv, shine_centers.zw, vec2(0.055, 0.040)));
	shine = mix(shine, hearts, heart_shines);
	color = mix(color, vec3(0.96), shine * tint.a * inside);
	vec3 emission = color * glow;
	lid_mask = 0.0;
	if (lid_amount > 0.0) {
		float x = (UV.x - 0.5) * nose_sign;
		float v = UV.y;
		float aa = max(fwidth(v), 1e-4);
		float top = show_lid_top(x);
		float bottom = show_lid_bottom(x);
		// Lid skin above the line and below the lower lid; the ink line just under the upper edge.
		float upper_skin = 1.0 - smoothstep(top - aa, top + aa, v);
		float lower_skin = smoothstep(bottom - aa, bottom + aa, v);
		float line = (1.0 - upper_skin) * (1.0 - smoothstep(top + lid_upper.w - aa, top + lid_upper.w + aa, v));
		// The outline wraps round the outer corner and thins out along the bottom.
		float inner_bottom = show_lid_bottom_at(x, lid_ends.x + lid_lower.w);
		float middle = 0.5 * (lid_ends.x + lid_ends.y);
		line = max(line, smoothstep(inner_bottom - aa, inner_bottom + aa, v) * (1.0 - smoothstep(middle - 0.2, middle, x)));
		float skin = max(upper_skin, lower_skin);
		vec3 coat = mix(lid_coat.rgb, lid_coat_shade.rgb, lid_coat_shade.a);
		color = mix(color, lid_ink.rgb, line * (1.0 - skin));
		color = mix(color, coat, skin);
		emission *= (1.0 - skin) * (1.0 - line);
		lid_mask = skin;
	}
	ALBEDO = color;
	EMISSION = emission;
	ROUGHNESS = mix(0.8, 1.0, lid_mask);
	SPECULAR = mix(0.15, 0.0, lid_mask);
}

void light() {
	if (lid_mask > 0.5) {
		DIFFUSE_LIGHT += diffuse_light(lid_coat.rgb, LIGHT_COLOR, LIGHT, NORMAL, ATTENUATION);
	} else {
		// Lambert for the eye itself, on the same scale as the cel include (LIGHT_COLOR carries PI).
		DIFFUSE_LIGHT += ALBEDO * LIGHT_COLOR * clamp(dot(NORMAL, LIGHT), 0.0, 1.0) * ATTENUATION / PI;
	}
}
