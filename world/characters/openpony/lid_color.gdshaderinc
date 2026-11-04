// Colour only the moving upper skin inside the original eye opening. The
// Blender attribute identifies upper-lid skin; it is not a feathered paint mask.
uniform vec4 eyelid_color : source_color = vec4(0.0);
uniform vec2 eyelid_weights = vec2(0.0);
uniform mat4 eyelid_rest_from_pose = mat4(1.0);
varying vec2 eyelid_region;
varying vec3 eyelid_position;

float lid_color_coverage() {
	vec3 p = eyelid_position;
	float x = (-(abs(p.x) - 0.072) + (-p.z - 0.357)) * 0.7071067812 / 0.110 - 0.004 / 0.110;
	float y = 0.5 - (p.y - 0.920) / 0.148;
	// Smooth conic fitted to the actual Blender liner's neutral contour.
	// As the lid retracts, its colour disappears behind that contour instead
	// of being compressed into a patch on the forehead. Only a pixel of AA.
	float edge = -2.85472243*x*x + 0.58196072*x*y - 7.24897094*y*y - 1.65669624*x + 7.68471236*y - 1.0;
	float aa = max(fwidth(edge), 0.001);
	float upper_skin = step(0.0001, max(eyelid_region.x, eyelid_region.y));
	float amount = p.x > 0.0 ? eyelid_weights.x : eyelid_weights.y;
	return smoothstep(-aa, aa, edge) * upper_skin * amount;
}

vec3 colored_lid(vec3 surface, vec3 shade_ratio) {
	if (eyelid_color.a <= 0.0 || max(eyelid_weights.x, eyelid_weights.y) <= 0.0) return surface;
	return mix(surface, eyelid_color.rgb * shade_ratio, lid_color_coverage() * eyelid_color.a);
}

// Painted freckles (Applejack's six, dev 2026-11-03): round spots fixed in head UV space, so
// they ride the moving cheek skin. xy = UV centre, z = radius in UV units (z <= 0 unused),
// w = how much the UV is stretched vertically there (1 or 0 = none), keeping the spots round.
uniform vec4 freckle_color : source_color = vec4(0.0);
uniform vec4 freckle_spots[6];

float freckle_coverage(vec2 uv) {
	float covered = 0.0;
	for (int i = 0; i < 6; i++) {
		vec4 spot = freckle_spots[i];
		if (spot.z <= 0.0) continue;
		vec2 delta = uv - spot.xy;
		delta.y *= spot.w > 0.0 ? spot.w : 1.0;
		float d = length(delta) / spot.z;
		float aa = max(fwidth(d), 0.001);
		covered = max(covered, 1.0 - smoothstep(1.0 - aa, 1.0 + aa, d));
	}
	return covered;
}

vec3 freckled(vec3 surface, vec3 shade_ratio, vec2 uv) {
	if (freckle_color.a <= 0.0) return surface;
	return mix(surface, freckle_color.rgb * shade_ratio, freckle_coverage(uv) * freckle_color.a);
}
