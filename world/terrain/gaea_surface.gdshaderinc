// Look 2026-11-10: cloud shadows on the ground read the shared look values.
#include "res://world/look/look.gdshaderinc"
// Seasons: every season_* global and the shared functions (snow cover, wetness, climate) come
// from res://world/seasons/season.gdshaderinc; res://world/seasons/season_state.gd writes them.
// The ground look itself (tint, snow, litter, wet, puddles) is in gaea_fragment.gdshaderinc.
#include "res://world/seasons/season.gdshaderinc"
// Ground-season inputs bound on this material by res://world/seasons/snow_trail.gd (W2-SEAS-B):
// tree-crown shelter near the camera (R 1 = under a crown; rect = x0, z0, width, depth, width 0 =
// none), the quality tier's wet look and puddles, and the falling rain (ripples in puddles).
uniform sampler2D season_shelter_map : filter_linear, repeat_disable;
uniform vec4 season_shelter_rect = vec4(0.0);
uniform bool season_wet_surfaces = true;
uniform bool season_puddles = false;
uniform float season_rain = 0.0;
// The grass colour probe's only layer (ground_grass.gd PROBE_LAYER): the probe keeps snow (blades
// read it) but not litter or wetness (the blades add those themselves, so the probe never lags).
const uint SEASON_PROBE_LAYERS = 524288u;
// Spring: how strongly a flower drift tints the ground beyond the grass (gaea_fragment.gdshaderinc).
const float LOOK_SPRING_GROUND = 0.28;
// Derived from the accepted study shader; see tools/build_gaea_material.py.
uniform vec4 gaea_grass_region = vec4(0.0);
uniform int gaea_grass_slot = 0;
uniform bool gaea_original_grass = false;
float gaea_grass_weight(vec2 point) {
    return gaea_grass_region.w > gaea_grass_region.z ?
        1.0-smoothstep(gaea_grass_region.z,gaea_grass_region.w,length(point-gaea_grass_region.xy)) : 0.0;
}
uniform sampler2D grass_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray surface_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec3 surface_mean[10];
uniform bool antitiling_enabled = true;



uint mix_bits(uint v) {
    v = (v ^ (v >> 16u)) * 2246822519u;
    v = (v ^ (v >> 13u)) * 3266489917u;
    return v ^ (v >> 16u);
}

vec3 tile_random(vec2 cell) {
    ivec2 i = ivec2(cell);
    uint h = mix_bits(uint(i.x) * 1597334677u ^ uint(i.y) * 3812015801u);
    return vec3(float(h & 65535u),float((h >> 16u) & 65535u),
                float(mix_bits(h+1013904223u) & 65535u))/65535.0;
}

vec3 shifted_sample(int slot, vec2 uv, vec2 dx, vec2 dy, vec2 cell) {
    vec3 seed = tile_random(cell);
    float angle = seed.z * 6.28318530718;
    mat2 rotation = mat2(vec2(cos(angle),sin(angle)),vec2(-sin(angle),cos(angle)));
    // Explicit gradients come from continuous world coordinates, not the random
    // offset. Otherwise mip selection blurs into lines at cell boundaries.
    return textureGrad(surface_tex,vec3(rotation*uv+seed.xy,float(slot)),rotation*dx,rotation*dy).rgb;
}

vec3 untiled(int slot, vec2 uv, vec2 dx, vec2 dy) {
    vec2 grid = vec2(uv.x-uv.y*0.57735026919,uv.y*1.15470053838);
    vec2 cell = floor(grid);
    vec2 f = fract(grid);
    vec2 a; vec2 b; vec2 c; vec3 w;
    if (f.x+f.y < 1.0) {
        a=cell; b=cell+vec2(1,0); c=cell+vec2(0,1);
        w=vec3(1.0-f.x-f.y,f.x,f.y);
    } else {
        a=cell+vec2(1,1); b=cell+vec2(0,1); c=cell+vec2(1,0);
        w=vec3(f.x+f.y-1.0,1.0-f.x,1.0-f.y);
    }
    w = w*w*w;
    w /= dot(w,vec3(1.0));
    vec3 color = shifted_sample(slot,uv,dx,dy,a)*w.x
                +shifted_sample(slot,uv,dx,dy,b)*w.y
                +shifted_sample(slot,uv,dx,dy,c)*w.z;
    // Approximate variance preservation: prevent washed-out blend centres.
    // This is not the full histogram-transform method of Deliot/Heitz.
    vec3 average=surface_mean[slot];
    return clamp(average+(color-average)*inversesqrt(dot(w,w)),vec3(0),vec3(1));
}

float broad_variation(vec2 p) {
    vec2 c=floor(p); vec2 f=fract(p); f=f*f*(3.0-2.0*f);
    return mix(mix(tile_random(c).x,tile_random(c+vec2(1,0)).x,f.x),
               mix(tile_random(c+vec2(0,1)).x,tile_random(c+vec2(1,1)).x,f.x),f.y);
}


vec3 material_pair(float choice, vec2 uv, vec2 dx, vec2 dy) {
    int a=int(floor(choice));
    float blend=smoothstep(0.0,1.0,fract(choice));
    vec3 first=untiled(a,uv,dx,dy);
    if (blend<0.001 || a==9) return first;
    return mix(first,untiled(a+1,uv,dx,dy),blend);
}

vec3 gaea_albedo(vec3 world_position, vec3 world_normal, vec4 paint, float favorite) {
    vec3 result;
    vec3 n=normalize(world_normal);
    vec3 weights=pow(abs(n),vec3(4.0));
    weights/=max(dot(weights,vec3(1.0)),0.0001);
    vec3 p=world_position/24.0;
    vec3 dx=dFdx(p); vec3 dy=dFdy(p);
    vec2 uv=world_position.xz/6.0;
    vec2 gx=dFdx(uv); vec2 gy=dFdy(uv);
    vec3 rock=vec3(0); vec3 ground=vec3(0);
    float macro;
    if (antitiling_enabled) {
        // Sharper projection preserves painted rock detail. Prune only the
        // near-zero blend tails, then renormalize; zero-weight axes cost no reads.
        weights=max(pow(abs(n),vec3(8.0))-vec3(.005),vec3(0));
        weights/=max(dot(weights,vec3(1)),.0001);
        float patch=broad_variation(world_position.xz/85.0);
        if (paint.r>0.0) {
            // Grey cliff rock only (dev 2026-09-24): Stones_01/03 read as rusty brown
            // dirt on the mountains, so the loose-stone shoulders use the cliff rock too.
            float stone=9.0;
            if (weights.x>0.0) rock+=material_pair(stone,p.zy,dx.zy,dy.zy)*weights.x;
            if (weights.y>0.0) rock+=material_pair(stone,p.xz,dx.xz,dy.xz)*weights.y;
            if (weights.z>0.0) rock+=material_pair(stone,p.xy,dx.xy,dy.xy)*weights.z;
        }
        if (paint.r<1.0) {
            if (paint.b<.999) {
                // Keep the selected image's original color; interpolate albedo,
                // not palette indices (which would visit unwanted textures).
                // Grass variants only; GrassAndDirt/Dirt (slots 2-3) were the brown patches.
                if (favorite < .999) ground=material_pair(clamp(paint.g*3.0,0.0,1.0),uv,gx,gy)*vec3(.60,.82,.64);
                if (favorite > .001) ground=mix(ground,untiled(gaea_grass_slot,uv,gx,gy),favorite);
            }
            if (paint.b>.001) {
                vec3 bank=material_pair(4.0+patch,uv,gx,gy);
                // Darken damp sediment towards water; keep the dry outer sand.
                bank*=mix(vec3(.94,.89,.81),vec3(.53,.58,.57),paint.b);
                ground=mix(ground,bank,paint.b);
            }
        }
        macro=.93+.10*broad_variation(world_position.xz/190.0);
        result=mix(ground,rock*vec3(.86,.91,.97),paint.r)*macro;
    } else {
        p=world_position/42.0;
        rock=texture(rock_tex,p.zy).rgb*weights.x+texture(rock_tex,p.xz).rgb*weights.y+texture(rock_tex,p.xy).rgb*weights.z;
        ground=texture(grass_tex,world_position.xz/18.0).rgb;
        macro=.94+.06*sin(world_position.x*.009+sin(world_position.z*.006));
        result=mix(ground*vec3(.80,.89,.70),rock*vec3(.87,.90,.94),paint.r)*macro;
    }
    return result;
}

// Only natural surface categories. Live native roads, mud, forest and snow remain.
uniform sampler2D gaea_field : filter_linear, repeat_disable;
uniform vec2 gaea_origin;
uniform vec2 gaea_samples;
uniform float gaea_cell=8.0;
uniform bool gaea_enabled=true;
float gaea_rock(int id) {
    return (id==6 || id==7 || id==12 || id==13 || id==14 || id==15 || id==21) ? 1.0 : 0.0;
}
float gaea_natural(int id) {
    return (id==0 || id==2 || id==3 || id==17 || id==18) ? 1.0 : gaea_rock(id);
}

// Ground seasons (W2-SEAS-B 2026-11-08). Trodden ids: dirt trail, town dirt, gravel. Forest floor:
// damp forest floor (dense canopy), gloomy grass (open forest). CPU mirror: snow_trail.gd shelter_at.
float season_road_id(int id) {
	return (id == 1 || id == 4 || id == 5) ? 1.0 : 0.0;
}
float season_forest_id(int id) {
	return id == 11 ? .8 : (id == 10 ? .45 : 0.0);
}
// Road share of the control texel nearest a Terrain3D uv (world metres x vertex density).
float season_road_texel(vec2 at) {
	ivec3 c = get_index_coord(at, FRAGMENT_PASS);
	if (c.z < 0) return 0.0;
	uint bits = floatBitsToUint(texelFetch(_control_maps, c, 0).r);
	return mix(season_road_id(DECODE_BASE(bits)), season_road_id(DECODE_OVER(bits)), DECODE_BLEND(bits));
}
// Tree-crown shelter near the camera, faded out over the last 12% of the window.
float season_canopy(vec2 xz) {
	if (season_shelter_rect.z <= 0.0) return 0.0;
	vec2 suv = (xz - season_shelter_rect.xy) / season_shelter_rect.zw;
	float edge = min(min(suv.x, suv.y), min(1.0 - suv.x, 1.0 - suv.y));
	if (edge <= 0.0) return 0.0;
	return textureLod(season_shelter_map, suv, 0.0).r * smoothstep(0.0, .12, edge);
}
// Puddle share at a point: flat ground x sine blobs, more of it floods as it gets wetter. The exact
// formula of world/audio/ground_contact_audio.gd puddle_at (W2-SEAS-J), so a splash is heard where
// a puddle is seen; change both together. wet = season_wet_amount(p).
float season_puddle(vec3 p, vec3 n, float wet) {
	if (wet < .35) return 0.0;
	float level_ground = smoothstep(.975, .995, n.y);   // (`flat` is a shader keyword)
	if (level_ground <= 0.0) return 0.0;
	float blobs = .5 + .25 * (sin(p.x * .43 + sin(p.z * .29) * 1.7) + sin(p.z * .37 + p.x * .19));
	float level = 1.05 - wet * .45;
	return level_ground * smoothstep(level, level + .1, blobs);
}
// Rain rings on puddles: two offset grids of 0.4 m cells, one ring growing in each.
vec2 season_ripples(vec2 xz, float t) {
	vec2 sum = vec2(0.0);
	for (int i = 0; i < 2; i++) {
		vec2 p = xz * 2.5 + float(i) * 7.31;
		vec3 rnd = tile_random(floor(p) + float(i) * 31.0);
		float phase = fract(t * .9 + rnd.z);
		vec2 d = fract(p) - (.25 + rnd.xy * .5);
		float r = length(d);
		float x = (r - phase * .5) * 30.0;
		if (abs(x) < 3.14159) sum += d / max(r, .001) * sin(x) * (1.0 - phase) * .35;
	}
	return sum;
}
