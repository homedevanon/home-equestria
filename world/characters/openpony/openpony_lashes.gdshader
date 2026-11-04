// The authored rig uses a fitted liner and flat lash blades with bound roots.
// The native ring path remains available for heads without that authored mesh.
shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_disabled;

uniform vec4 lash_color : source_color = vec4(0.018, 0.012, 0.025, 1.0);
uniform float band_width : hint_range(0.004, 0.04) = 0.018;
uniform bool use_native_ring = false;
// Authored parts: liner (black), legacy curved fan (red), shadow (green),
// flat cutout blades (blue). Only the blades project beyond the lid corner.
uniform bool authored_liner = false;
uniform sampler2D native_lash_texture : source_color, filter_linear_mipmap, repeat_disable;
// Three lash tips as UV triangles (a, b on the rim, c the tip) per character
// (world/characters/hybrid_mare/lash_styles.gd); defaults are Dash's measured tips.
// (uniform arrays take no defaults: an unset array draws no tips; hybrid_mare sets it.)
uniform vec2 tips[9];
// Stallions retain the painted eyelid ring without the projecting strokes.
uniform bool show_lash_tips = true;
// Bends each tip: the outer half of the tip is pushed toward the eye's upper side.
uniform float tip_curl : hint_range(0.0, 1.0) = 0.0;
// Expression lash fan; its bases remain on the same morphed ring.
uniform float sculpt_amount = 0.0;
// Rarity's light-blue lid; alpha 0 = none. Drawn as a band above the lash rim.
uniform vec4 eyeshadow_color : source_color = vec4(0.72, 0.88, 0.94, 0.0);
// Show lids drawn on the eye (dev 2026-11-02, show_lid.gd): the ring's outline above the drawn upper
// lid and below the drawn lower lid gives way to it, all of it once the lid is half in; the lash tips
// stay. The ring is judged where it
// sits on the open, modelled eye: show_lid.gd baked_ring stores each vertex's rest nose-x / v in
// CUSTOM0, so lid bones pulling the ring down onto a squeezed eye do not move what it covers.
#include "res://world/characters/openpony/show_lid.gdshaderinc"
varying vec2 lid_xy;

void vertex() {
	lid_xy = CUSTOM0.xy;
}

// Upper inner boundary measured directly from the native GLB's lash UVs.
float upper_rim(float u) {
	if (u < 0.2315) return mix(0.6157, 0.5929, clamp((u - 0.2086) / 0.0229, 0.0, 1.0));
	if (u < 0.2745) return mix(0.5929, 0.5848, (u - 0.2315) / 0.0430);
	if (u < 0.3447) return mix(0.5848, 0.5773, (u - 0.2745) / 0.0702);
	if (u < 0.4172) return mix(0.5773, 0.5737, (u - 0.3447) / 0.0725);
	if (u < 0.4855) return mix(0.5737, 0.5735, (u - 0.4172) / 0.0683);
	if (u < 0.5499) return mix(0.5735, 0.5780, (u - 0.4855) / 0.0644);
	if (u < 0.6073) return mix(0.5780, 0.5867, (u - 0.5499) / 0.0574);
	if (u < 0.6532) return mix(0.5867, 0.5950, (u - 0.6073) / 0.0459);
	if (u < 0.6916) return mix(0.5950, 0.6048, (u - 0.6532) / 0.0384);
	return mix(0.6048, 0.6149, clamp((u - 0.6916) / 0.0244, 0.0, 1.0));
}

float triangle(vec2 p, vec2 a, vec2 b, vec2 c) {
	vec2 v0 = c - a;
	vec2 v1 = b - a;
	vec2 v2 = p - a;
	float inv = 1.0 / (v0.x * v1.y - v1.x * v0.y);
	float u = (v2.x * v1.y - v1.x * v2.y) * inv;
	float v = (v0.x * v2.y - v2.x * v0.y) * inv;
	return step(0.0, min(min(u, v), 1.0 - u - v));
}

// Monotonic outer-corner curves on the authored lash surface. Thickness tapers
// to a point; the common root stays on the moving upper rim.
float sculpt_lash(vec2 p, vec2 a, float bend_v, vec2 c) {
	float t = clamp((p.x - a.x) / (c.x - a.x), 0.0, 1.0);
	float v = (1.0 - t) * (1.0 - t) * a.y + 2.0 * t * (1.0 - t) * bend_v + t * t * c.y;
	float width = 0.040 * pow(1.0 - t, 0.7);
	float aa = max(fwidth(p.y), 0.0001);
	return step(a.x, p.x) * step(p.x, c.x) * (1.0 - smoothstep(width - aa, width + aa, abs(p.y - v)));
}

void fragment() {
	float rim = upper_rim(UV.x);
	float taper = smoothstep(0.205, 0.25, UV.x) * (1.0 - smoothstep(0.64, 0.718, UV.x));
	float band = step(rim - band_width * taper, UV.y) * step(UV.y, rim + 0.002);
	band *= step(0.2086, UV.x) * step(UV.x, 0.718);
	if (use_native_ring) {
		float native_band = texture(native_lash_texture, UV).a;
		if (sculpt_amount > 0.0) {
			// Fuller liner on the morphed ring; lash tips have separate controls.
			vec2 expansion = vec2(0.006, 0.004) * sculpt_amount;
			native_band = max(native_band, max(texture(native_lash_texture, UV + vec2(expansion.x, 0.0)).a,
				texture(native_lash_texture, UV - vec2(expansion.x, 0.0)).a));
			native_band = max(native_band, max(texture(native_lash_texture, UV + vec2(0.0, expansion.y)).a,
				texture(native_lash_texture, UV - vec2(0.0, expansion.y)).a));
		}
		// The compact eye needs a consistent upper stroke. UV thickness survives the
		// authored geometry; its original lower and outer ring tapers remain available.
		float upper_stroke = step(rim - 0.065 * taper, UV.y) * step(UV.y, rim + 0.065 * taper)
			* step(0.2086, UV.x) * step(UV.x, 0.718);
		band = max(native_band, upper_stroke * sculpt_amount);
	}
	// Native U increases AWAY from the nose on both mirrored eye surfaces.
	// Measured rim: u=.23 at |x|=.044 m, u=.70 at |x|=.133 m.
	float lashes = 0.0;
	for (int i = 0; i < 3 && show_lash_tips; i++) {
		vec2 a = tips[i * 3];
		vec2 b = tips[i * 3 + 1];
		vec2 c = tips[i * 3 + 2];
		// Curl: a quadratic bend of the triangle's tip toward the upper side (smaller V).
		vec2 mid = (a + b) * 0.5;
		vec2 along = c - mid;
		float t = clamp(dot(UV - mid, along) / max(dot(along, along), 1e-6), 0.0, 1.0);
		vec2 bent = UV + vec2(0.0, tip_curl * 0.06 * t * t);
		lashes = max(lashes, triangle(bent, a, b, c));
	}
	if (sculpt_amount > 0.0 && show_lash_tips) {
		float fan = max(sculpt_lash(UV, vec2(0.68, 0.602), 0.690, vec2(0.84, 0.65)),
			max(sculpt_lash(UV, vec2(0.68, 0.586), 0.600, vec2(0.84, 0.51)),
				sculpt_lash(UV, vec2(0.68, 0.570), 0.515, vec2(0.79, 0.43))));
		lashes = mix(lashes, fan, sculpt_amount);
	}
	// Eyeshadow: a band above the lash rim across the visible lid, inside the native U span.
	float shadow = step(rim - 0.062, UV.y) * step(UV.y, rim - band_width * taper)
		* step(0.2086, UV.x) * step(UV.x, 0.718) * eyeshadow_color.a;
	if (lid_amount > 0.0) {
		float top = show_lid_top(lid_xy.x);
		float bottom = show_lid_bottom(lid_xy.x);
		float covered = 1.0 - step(top + 0.01, lid_xy.y) * step(lid_xy.y, bottom - 0.01);
		// Once the drawn lid is mostly in, its own outline (iris.gdshader) draws every edge.
		covered = max(covered, step(0.5, lid_amount));
		band *= 1.0 - covered;
		shadow *= 1.0 - covered;
	}
	float ink = max(band, lashes);
	if (authored_liner) {
		// The root overlaps the authored ribbon; the original rounded tips stay.
		float fan = max(sculpt_lash(UV, vec2(0.66, 0.602), 0.690, vec2(0.84, 0.65)),
			max(sculpt_lash(UV, vec2(0.66, 0.586), 0.600, vec2(0.84, 0.51)),
				sculpt_lash(UV, vec2(0.66, 0.570), 0.515, vec2(0.79, 0.43))));
		if (COLOR.g > 0.5) {
			ink = 0.0;
		} else if (COLOR.b > 0.5) {
			// Rigid flat cutout, authored in Blender. Its silhouette is geometry;
			// every expression moves the whole fan from one lid-corner attachment.
			ink = show_lash_tips ? 1.0 : 0.0;
			shadow = 0.0;
		} else {
			ink = COLOR.r < 0.5 ? 1.0 : (show_lash_tips ? fan : 0.0);
			shadow = 0.0;
		}
	}
	ALBEDO = mix(eyeshadow_color.rgb, lash_color.rgb, step(0.5, ink));
	ALPHA = max(ink, shadow);
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	ROUGHNESS = 1.0;
}
