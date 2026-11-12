
	if (gaea_amount>.001) {
		ALBEDO=mix(ALBEDO,gaea_albedo(v_vertex,w_normal,gaea_style,gaea_favorite)*color_map.rgb,gaea_amount);
	}

	// Seasons: green ground turns toward the season's colour (value kept). The uniforms and the
	// shared functions come from res://world/seasons/season.gdshaderinc (via gaea_surface).
	{
		vec3 s_luma = vec3(.2126, .7152, .0722);
		vec3 s_chroma = ALBEDO / max(max(ALBEDO.r, max(ALBEDO.g, ALBEDO.b)), .0001);
		float s_green = smoothstep(.02, .18, s_chroma.g - s_chroma.r) * smoothstep(.02, .2, s_chroma.g - s_chroma.b);
		vec3 s_turned = season_ground.rgb * (dot(ALBEDO, s_luma) / max(dot(season_ground.rgb, s_luma), .00001));
		ALBEDO = mix(ALBEDO, s_turned, clamp(season_ground.a * s_green, 0.0, 1.0));
	}

	// Spring flower drifts beyond the grass (125 m): the meadow keeps the drifts' colour bands to
	// the horizon (season.gdshaderinc). Not in the orthographic ground-colour probe the grass
	// reads, or every blade near the eye would take the tint. LOOK_SPRING_GROUND = 0.0 removes it.
	if (season_spring > .0005 && LOOK_SPRING_GROUND > 0.0 && PROJECTION_MATRIX[3][3] < .5 && v_vertex_xz_dist > 60.0) {
		vec3 f_chroma = ALBEDO / max(max(ALBEDO.r, max(ALBEDO.g, ALBEDO.b)), .0001);
		float f_green = smoothstep(.02, .18, f_chroma.g - f_chroma.r) * smoothstep(.02, .2, f_chroma.g - f_chroma.b);
		float f_on = LOOK_SPRING_GROUND * season_flower_bloom() * smoothstep(60.0, 125.0, v_vertex_xz_dist) * season_flower_drift(v_vertex.xz) * f_green;
		if (f_on > .001) ALBEDO = mix(ALBEDO, season_flower_palette(int(season_flower_pick(v_vertex.xz) * 8.0)), f_on);
	}

	// Ground seasons (W2-SEAS-B 2026-11-08): snow that settles where it can lie (season_snow_on:
	// up-facing x climate x drifts x cover, minus trodden trails), but not on trodden roads (2 m
	// past their edge too), the forest floor or under tree crowns; leaf litter under trees; rain-
	// wet ground and puddles. A dry, snowless, leafless pixel pays these three uniform tests only.
	if (season_snow_cover > .001 || season_leaf_litter > .001 || season_wetness > .001) {
		vec3 s_n = normalize(w_normal);
		float s_road = 0.0; float s_forest = 0.0; float s_rock = 0.0;
		for (int si = 0; si < 4; si++) {
			float sw = bilerp ? weights[si] : (si == 3 ? 1.0 : 0.0);
			if (sw <= 0.0) continue;
			uint sc = control[si];
			int sb = DECODE_BASE(sc); int so = DECODE_OVER(sc); float sm = DECODE_BLEND(sc);
			s_road += sw * mix(season_road_id(sb), season_road_id(so), sm);
			s_forest += sw * mix(season_forest_id(sb), season_forest_id(so), sm);
			s_rock += sw * mix(gaea_rock(sb), gaea_rock(so), sm);
		}
		float s_canopy = season_canopy(v_vertex.xz);
		bool s_probe = CAMERA_VISIBLE_LAYERS == SEASON_PROBE_LAYERS;
		float s_cover = 0.0;
		if (season_snow_cover > .001) {
			s_cover = season_snow_on(s_n, v_vertex);
			if (s_cover > .001) {
				// The 2 m road verge needs four more control reads: only where snow would lie,
				// and only within 250 m (farther, a 2 m strip is a pixel or two).
				float s_trodden = s_road;
				if (v_vertex_xz_dist < 250.0) {
					// Look 2026-11-10 (dev: "the snow is still square around the roads, like it's
					// pixelated"): the road paint is a 1 m grid, and the snow's edge followed its
					// steps. Now the edge is read on two rings of four points around a centre that
					// noise pushes about, and blended: a soft line that wanders, as drifted snow does.
					// Old rule: four reads at 2 m, s_trodden = max(s_road, half their sum).
					vec2 s_push = (vec2(broad_variation(v_vertex.xz * .7), broad_variation(v_vertex.xz * .7 + 31.7)) - .5) * 2.2 * _vertex_density;
					vec2 s_at = uv + s_push;
					float s_near = 1.2 * _vertex_density;
					float s_far = 2.6 * _vertex_density;
					float s_ring_a = season_road_texel(s_at + vec2(s_near, s_near)) + season_road_texel(s_at + vec2(-s_near, s_near))
						+ season_road_texel(s_at + vec2(s_near, -s_near)) + season_road_texel(s_at + vec2(-s_near, -s_near));
					float s_ring_b = season_road_texel(s_at + vec2(s_far, 0.0)) + season_road_texel(s_at - vec2(s_far, 0.0))
						+ season_road_texel(s_at + vec2(0.0, s_far)) + season_road_texel(s_at - vec2(0.0, s_far));
					float s_soft = (s_road * 2.0 + s_ring_a + s_ring_b * .75) / 9.0;
					s_trodden = smoothstep(.14, .72, s_soft);
				}
				// Look 2026-11-10: in deep winter the roads are trodden snow, not bare strips (a light
				// dusting still leaves them clear). Old rule: s_trodden * .85 at every depth.
				float s_road_clear = mix(.85, .42, smoothstep(.5, .9, season_snow_cover));
				s_cover *= 1.0 - max(s_trodden * s_road_clear, max(s_forest, s_canopy * .85));
			}
			if (s_cover > .001) {
				// Deep drifts: bright, a cold blue on their sloped flanks, softer bumps; trodden
				// snow a little greyer.
				vec3 s_snow = season_snow_albedo(ALBEDO, s_cover);
				float s_deep = smoothstep(.6, 1.0, s_cover);
				s_snow *= mix(vec3(1.0), vec3(.93, .96, 1.02), s_deep * clamp((1.0 - s_n.y) * 8.0, 0.0, 1.0));
				ALBEDO = s_snow * (1.0 - .12 * season_snow_trail(v_vertex.xz));
				roughness = mix(roughness, .82, s_cover);
				// Look 2026-11-10: scattered crystals that catch the sun or the moon, near the eye only
				// (farther they would shimmer). Remove this block to go back to matte snow.
				if (v_vertex_xz_dist < 30.0) {
					vec2 g_cell = floor(v_vertex.xz * 28.0);
					float g_hash = fract(sin(dot(g_cell, vec2(12.9898, 78.233))) * 43758.5453);
					roughness = mix(roughness, .06, step(.985, g_hash) * s_cover * (1.0 - v_vertex_xz_dist / 30.0));
				}
				mat.normal_rough.xz *= 1.0 - .7 * s_cover;
				mat.normal_map_depth *= 1.0 - .6 * s_cover;
			}
		}
		if (season_leaf_litter > .001 && !s_probe) {
			// Fallen leaves: thick under crowns and on the forest floor, a few blown over open
			// ground, none on rock, thinner on roads, buried by snow. Deciduous share = climate G.
			float l_under = max(clamp(s_forest * 2.0, 0.0, 1.0), s_canopy);
			float l_amount = season_leaf_litter * season_climate(v_vertex.xz, 1) * mix(.2, 1.0, l_under)
				* (1.0 - .8 * s_road) * (1.0 - s_cover) * (1.0 - s_rock);
			if (l_amount > .001) {
				float l_patch = broad_variation(v_vertex.xz / 3.0) * .6 + broad_variation(v_vertex.xz / .7) * .4;
				// A ragged edge at the size of a leaf, so a patch ends in scattered leaves and not
				// in a painted outline (dev 2026-11-10: the litter was two flat colours).
				// Far away a leaf is smaller than a pixel: there the detail fades to its average,
				// or it would shimmer as the eye moves.
				float l_near = 1.0 - smoothstep(.04, .12, max(fwidth(v_vertex.x), fwidth(v_vertex.z)));
				// Perf 2026-11-11, same picture: far away (l_near 0) the leaf detail is its average
				// and is not read; where no litter shows (l_mask 0) its colour is not worked out.
				float l_leaf = l_near > 0.0 ? mix(.5, broad_variation(v_vertex.xz / .11), l_near) : .5;
				float l_mask = smoothstep(1.05 - l_amount, 1.25 - l_amount, l_patch + .25 + (l_leaf - .5) * .22);
				if (l_mask > 0.0) {
					// Leaf by leaf: gold, orange, red and brown, more brown as the season ends.
					vec3 l_bright = vec3(.74, .38, .09);
					if (l_near > 0.0) {
						float l_pick = broad_variation(v_vertex.xz / .16 + vec2(31.7, 12.3));
						vec3 l_one = l_pick < .4 ? vec3(.80, .55, .12) : (l_pick < .75 ? vec3(.78, .33, .07) : vec3(.55, .14, .08));
						l_bright = mix(l_bright, l_one, l_near);
					}
					float l_brown = max(smoothstep(.55, .95, season_leaf_turn), broad_variation(v_vertex.xz / 1.3) * .55);
					vec3 l_col = mix(l_bright, vec3(.32, .2, .09), l_brown) * mix(.7, 1.0, l_leaf);
					ALBEDO = mix(ALBEDO, l_col, l_mask);
					roughness = mix(roughness, .9, l_mask);
				}
			}
		}
		if (season_wetness > .001 && season_wet_surfaces && !s_probe) {
			// Rain-wet ground: darker and smoother; less under shelter and none on snow. Puddles on
			// flat ground (season_puddle = the footstep splash formula), mirror-smooth, ringed
			// while it rains; not on rock or snow.
			float w_ground = season_wet_amount(v_vertex);
			float w_amount = w_ground * (1.0 - s_cover) * (1.0 - .6 * max(s_forest, s_canopy));
			season_wet(ALBEDO, roughness, w_amount);
			if (season_puddles && w_ground >= .35) {
				float p_mask = season_puddle(v_vertex, s_n, w_ground) * (1.0 - s_rock) * (1.0 - s_cover);
				if (p_mask > .001) {
					ALBEDO = mix(ALBEDO, ALBEDO * .45 + vec3(.015, .02, .025), p_mask);
					roughness = mix(roughness, .04, p_mask);
					vec2 p_ripple = season_rain > .01 ? season_ripples(v_vertex.xz, TIME) * season_rain : vec2(0.0);
					mat.normal_rough.xz = mix(mat.normal_rough.xz, p_ripple, p_mask);
					mat.normal_rough.y = mix(mat.normal_rough.y, 1.0, p_mask);
				}
			}
		}
	}

	// Snow caps (dev 2026-09-24): above ~700 m on ground flat enough to hold it; the line
	// wanders +-30 m so it does not read as a contour. Canterlot's city sits below 510 m.
	{
		vec3 c_world = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
		float c_line = 700.0 + 30.0 * (sin(c_world.x * .004 + sin(c_world.z * .003) * 2.0) + sin(c_world.z * .005 + c_world.x * .001));
		float c_cover = smoothstep(c_line - 60.0, c_line + 80.0, c_world.y) * smoothstep(.35, .62, normalize(w_normal).y);
		ALBEDO = mix(ALBEDO, vec3(.92, .94, .98), clamp(c_cover, 0.0, 1.0));
	}

	// Cloud shadows (look 2026-11-10): soft patches of shade that drift with the clouds, so the
	// far land is never one flat sheet of light. Ground only for now.
	if (look_cloud_shadow > .005) {
		vec2 c_p = v_vertex.xz + sky_cloud_offset;
		float c_n = .65 * broad_variation(c_p / 420.0) + .35 * broad_variation(c_p / 130.0 + 7.3);
		float c_cov = clamp(sky_cloud_shape.x, 0.0, 1.0);
		float c_shade = smoothstep(1.0 - c_cov - .05, 1.0 - c_cov + .22, c_n) * look_cloud_shadow;
		ALBEDO *= mix(vec3(1.0), vec3(.60, .66, .80), c_shade);
	}
