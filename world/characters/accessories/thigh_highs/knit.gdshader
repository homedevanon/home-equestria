shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;
uniform vec4 stripe_color : source_color = vec4(0.88, 0.48, 0.66, 1.0);
uniform vec4 cream_color : source_color = vec4(0.96, 0.93, 0.87, 1.0);
// 1 = cream stripes; 0 = one solid colour ("plain-socks").
uniform float stripes : hint_range(0.0, 1.0) = 1.0;
// A column of interlocking V stitches. Detail fades below pixel size, preventing shimmer.
float stitch(vec2 p) {
	vec2 cell = fract(p) - 0.5;
	float yarn = abs(abs(cell.x) - (0.22 + cell.y * 0.38));
	float loop = exp(-yarn * yarn * 150.0);
	return loop * (0.82 + 0.18 * cos(cell.y * 6.283185));
}
void fragment() {
	float cuff = COLOR.r;
	float width = max(fwidth(UV.y * 12.0), 0.008);
	float wave = sin((UV.y - 0.1) * 37.699112);
	float stripe = smoothstep(-width, width, wave);
	stripe = mix(stripe, 0.0, smoothstep(0.88, 0.92, UV.y));
	stripe *= smoothstep(0.075, 0.115, UV.y) * (1.0 - cuff) * stripes;
	vec2 knit_uv = UV * vec2(64.0, 108.0);
	float detail = 1.0 - smoothstep(0.35, 1.4, max(fwidth(knit_uv.x), fwidth(knit_uv.y)));
	float h = stitch(knit_uv);
	float dx = (stitch(knit_uv + vec2(0.035, 0.0)) - stitch(knit_uv - vec2(0.035, 0.0))) / 0.07;
	float dy = (stitch(knit_uv + vec2(0.0, 0.035)) - stitch(knit_uv - vec2(0.0, 0.035))) / 0.07;
	float ribs = sin(UV.x * 201.06193);
	vec3 n = normalize(vec3(-dx * 0.16 - ribs * cuff * 0.42, -dy * 0.16, 1.0));
	NORMAL_MAP = mix(vec3(0.5, 0.5, 1.0), n * 0.5 + 0.5, detail);
	vec3 base = mix(stripe_color.rgb, cream_color.rgb, stripe);
	ALBEDO = base * (1.0 - detail * (1.0 - h) * 0.13) * (1.0 - cuff * 0.06);
	ROUGHNESS = mix(0.90, 0.78 + 0.16 * h, detail);
	SPECULAR = 0.22;
	RIM = 0.18;
	RIM_TINT = 0.65;
}
