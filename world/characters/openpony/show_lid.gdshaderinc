// Show lids (dev 2026-11-02; world/characters/openpony/show_lid.gd): lid lines drawn on the eye in
// the show-eye frame, nose-x (eye widths, + toward the nose) and v (0 top of the art, 1 bottom).
// lid_upper / lid_lower = (base, slant, saddle, w): v = base + slant*x + saddle*x*x. The upper w is
// its ink line's thickness; the lower w is how far (nose-x) the outline wraps in round the outer end
// of the opening, thinning along the bottom toward the middle. lid_ends = (outer x, nose x, roundness): the lower lid bows up to meet the
// upper one at both ends (a superellipse, 2 round, higher squarer), so the opening is an almond with
// a straight top and a round bottom; outside it the lids cover the eye. lid_amount 0 leaves the eye
// as it was.
uniform float lid_amount = 0.0;
uniform vec4 lid_upper = vec4(0.42, 0.06, 0.25, 0.045);
uniform vec4 lid_lower = vec4(0.80, 0.04, 0.25, 0.0);
uniform vec4 lid_ends = vec4(-9.0, 9.0, 2.0, 0.0);

// Open positions the lids start from: above and below every part of the eye.
const float LID_OPEN_TOP = -0.25;
const float LID_OPEN_BOTTOM = 1.3;

float show_lid_top(float x) {
	return mix(LID_OPEN_TOP, lid_upper.x + lid_upper.y * x + lid_upper.z * x * x, lid_amount);
}

// The lower lid with the opening's outer end at outer (the eye's own end is lid_ends.x).
float show_lid_bottom_at(float x, float outer) {
	float top = lid_upper.x + lid_upper.y * x + lid_upper.z * x * x;
	float bottom = lid_lower.x + lid_lower.y * x + lid_lower.z * x * x;
	float half_width = max(0.5 * (lid_ends.y - outer), 1e-4);
	float t = min(abs(x - 0.5 * (outer + lid_ends.y)) / half_width, 1.0);
	float n = max(lid_ends.z, 0.5);
	float open = pow(max(1.0 - pow(t, n), 0.0), 1.0 / n);
	return mix(LID_OPEN_BOTTOM, mix(top, bottom, open), lid_amount);
}

float show_lid_bottom(float x) {
	return show_lid_bottom_at(x, lid_ends.x);
}
