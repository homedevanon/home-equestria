shader_type spatial;
// Falling snow (world/weather/snow_field.gd). Dev 2026-11-10: "you just make white circles and go
// YEP GOOD ENOUGH". A flake is not a white dot; it is a small white diffuser in the air:
//   - it shows whatever light reaches it: the blue of the dusk sky, the warm cone of a street
//     lamp, sunlight, or almost nothing in the dark. So it is lit by the scene's own lights
//     (light() below takes every light at full strength whatever its direction, as a tuft of
//     snow does) and by the sky's fill light. No tint is handed in from outside.
//   - it flutters: each flake sways on its own rhythm around the line the wind gives the fall.
//   - in still air it is a round soft tuft; in wind it is drawn as a dash along its path.
//   - far flakes sink into the haze like everything else (fog is not disabled).
//   - real snowfall holds about a thousand flakes in every cubic metre; this holds about one.
//     So a far flake stands for the many around it: it never shrinks below min_angle (an angle
//     at the eye, so the same on a monitor and in the headset) and thins out instead. Without
//     that the fall is a dozen dots near the eye and empty air behind.
//   - a flake about to touch the eye fades, so none fills the view.
// Where a flake is: every flake has a fixed path through the world (a start point from its
// number, plus `travel`, the distance the fall has covered, at its own pace). The box around
// the eye is a window onto those paths: a flake leaving one face enters at the opposite one,
// faded at the faces. Nothing is born or dies in view.
// The sprite is a real asset (world/vfx/textures/soft_dot.png, CC0) that dev may swap.
// World-space per flake: nothing here is a screen effect, so it holds up in the headset.
render_mode blend_mix, depth_draw_never, cull_disabled, shadows_disabled, skip_vertex_transform, specular_disabled;

uniform sampler2D flake : filter_linear_mipmap, repeat_disable;
uniform vec3 box_centre = vec3(0.0);
uniform vec3 box_half = vec3(6.0);
uniform vec3 travel = vec3(0.0);
uniform vec3 fall_direction = vec3(0.0, -1.0, 0.0);
// Length of the dash over its width: 1 in still air.
uniform float streak = 1.0;
// Sideways sway in metres.
uniform float flutter = 0.1;
uniform float opacity = 1.0;
// Scale on every flake (the wind makes the grain finer).
uniform float grain = 1.0;
// How much of a light's strength a flake returns. 1: as bright as white snow facing that light,
// whatever the flake's own facing. Measured 2026-11-10 at 0.26: a flake came out darker than the
// snow on the ground (0.88 of it), so the fall only showed against the sky.
uniform float catch_light = 1.0;
// The sky's light a flake carries on top of what a surface gets (weather.gd sets it from the fill light).
uniform vec3 sky_glow : source_color = vec3(0.0);
// Width of the flake quad in metres at scale 1.
uniform float quad = 0.036;
// Smallest angle a flake is drawn at, in radians, and how fast it thins once held at that size.
uniform float min_angle = 0.007;
uniform float far_fade = 0.55;

varying float v_alpha;

// One number in, a well-mixed number out (PCG). The flake's values are a chain of these, so its
// place, pace and size share nothing: with a weaker mix the flakes stood in visible rows.
uint mix_bits(uint v) {
	uint state = v * 747796405u + 2891336453u;
	uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
	return (word >> 22u) ^ word;
}

float unit(uint bits) {
	return float(bits >> 8u) / 16777215.0;
}

void vertex() {
	uint a = mix_bits(uint(INSTANCE_ID) + 1u);
	uint b = mix_bits(a);
	uint c = mix_bits(b);
	uint d = mix_bits(c);
	uint e = mix_bits(d);
	uint f = mix_bits(e);
	uint g = mix_bits(f);
	uint h = mix_bits(g);
	uint i = mix_bits(h);
	vec3 box = box_half * 2.0;
	float pace = 0.7 + 0.6 * unit(d);
	vec3 path = vec3(unit(a), unit(b), unit(c)) * box + travel * pace;
	vec3 local = mod(path - box_centre + box_half, box) - box_half;
	vec3 centre = box_centre + local;
	vec3 to_face = 1.0 - abs(local) / box_half;
	float inside = smoothstep(0.0, 0.2, min(to_face.x, min(to_face.y, to_face.z)));

	float phase = unit(e) * 6.2831853;
	float rate = 0.7 + unit(f) * 0.9;
	vec3 along = normalize(fall_direction);
	vec3 sway_a = normalize(cross(along, abs(along.y) > 0.99 ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 1.0, 0.0)));
	vec3 sway_b = cross(along, sway_a);
	centre += (sway_a * sin(TIME * rate + phase) + sway_b * sin(TIME * rate * 0.73 + phase * 1.7))
		* flutter * (0.5 + unit(g));

	// Many small, few large.
	float size = quad * grain * mix(0.45, 2.1, pow(unit(h), 2.2));
	float distance_to_eye = length(CAMERA_POSITION_WORLD - centre);
	float held = max(1.0, distance_to_eye * min_angle / max(size, 0.0001));
	size *= held;
	vec3 to_camera = normalize(CAMERA_POSITION_WORLD - centre);
	vec3 side = cross(along, to_camera);
	side = length(side) > 0.001 ? normalize(side) : vec3(1.0, 0.0, 0.0);
	vec3 world = centre + side * VERTEX.x * size + along * VERTEX.y * size * streak;
	VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	NORMAL = (VIEW_MATRIX * vec4(to_camera, 0.0)).xyz;
	// No two flakes equally dense.
	v_alpha = (0.6 + 0.4 * unit(i)) * inside * pow(1.0 / held, far_fade) * smoothstep(0.3, 1.2, distance_to_eye);
}

void fragment() {
	ALBEDO = vec3(0.95, 0.97, 1.0);
	EMISSION = sky_glow;
	// The sprite's wide soft skirt made each near flake a glowing orb; squared, it is a tuft.
	float body = texture(flake, UV).a;
	ALPHA = body * body * opacity * v_alpha;
	// Nearly two thirds of each quad is the sprite's invisible rim (under 1/255): those pixels
	// would still run the light loop.
	if (ALPHA < 0.004) discard;
}

void light() {
	DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * catch_light;
}
