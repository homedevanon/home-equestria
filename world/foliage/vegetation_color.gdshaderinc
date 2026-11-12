// Vegetation colour: ground hue, season tint, crown snow and leaf thinning for every tree, plant
// and impostor shader (leaf cards, far crowns, impostors, the native cel-shaded atlases).
#ifndef VEGETATION_COLOR_GDSHADERINC
#define VEGETATION_COLOR_GDSHADERINC
// Season globals and the contract functions (world/seasons/season.gdshaderinc, written only by
// world/seasons/season_state.gd). Do not declare any season_* uniform here or in an includer.
#include "res://world/seasons/season.gdshaderinc"

// RGB is a low-frequency ground palette; A says whether vegetation has support.
global uniform sampler2D vegetation_color_map : source_color, filter_linear, repeat_disable;
global uniform vec4 vegetation_color_rect;
global uniform bool vegetation_color_enabled;
// Per material: an evergreen (pines, spruce; world/foliage/vegetation_materials.gd sets it) never
// turns orange or drops its leaves, it only darkens a little and takes crown snow.
uniform bool evergreen = false;
// Per material: 1 on a blossom tree (the Grassy sakura; vegetation_materials.gd mark_blossom). In
// spring its cards fill out sooner and a growing share of them turn blossom pink.
uniform float blossom_tree = 0.0;

vec4 vegetation_ground(vec2 position) {
    if (!vegetation_color_enabled) return vec4(0.0);
    vec2 uv=(position-vegetation_color_rect.xy+vec2(8.0))/vegetation_color_rect.zw;
    if (any(lessThan(uv,vec2(0.0))) || any(greaterThan(uv,vec2(1.0)))) return vec4(0.0);
    return textureLod(vegetation_color_map,uv,0.0);
}
float vegetation_green_mask(vec3 sample_rgb) {
    vec3 chroma=sample_rgb/max(max(sample_rgb.r,max(sample_rgb.g,sample_rgb.b)),.0001);
    return smoothstep(.015,.16,chroma.g-chroma.r)*smoothstep(.02,.20,chroma.g-chroma.b);
}
// Spring blossom on a blossom tree: 1 when the card or texel with this pick (a stable 0..1) is in
// flower, up to 85% of them at the blossom peak (season_blossom 1).
float vegetation_blossom_on(float pick) {
    if (season_blossom<=.001 || blossom_tree<=0.0) return 0.0;
    return step(pick,season_blossom*.85*blossom_tree);
}
// Blossom pink over a leaf colour, a little brighter than the leaf it covers.
vec3 vegetation_blossom(vec3 c,float on) {
    if (on<=0.0) return c;
    float value=clamp(dot(c,vec3(.2126,.7152,.0722))/.3,.6,1.15);
    return mix(c,vec3(.98,.74,.85)*value,on);
}

// Ground hue only: keep source shading/detail, change chroma without flattening leaf value.
vec3 vegetation_ground_hue(vec3 authored,vec4 ground,float strength) {
    vec3 luma=vec3(.2126,.7152,.0722);
    vec3 matched=ground.rgb*(dot(authored,luma)/max(dot(ground.rgb,luma),.00001));
    return mix(authored,matched,clamp(strength*ground.a,0.0,1.0));
}

// Climate under a plant, read once per vertex (or per tree root): x = deciduous share (climate G;
// 0 in jungle/desert/coast keeps leaves green and on the tree), y = snow response (climate R; 0 =
// no crown snow, D-06). While no leaf tint, leaf drop or snow is active the fetch is skipped.
vec2 vegetation_season_local(vec2 xz) {
    if (season_leaf.a<=.001 && season_leaf_drop<=.001 && season_snow_cover<=.001) return vec2(1.0);
    if (season_climate_rect.z<=0.0) return vec2(1.0);
    vec2 uv=clamp((xz-season_climate_rect.xy)/season_climate_rect.zw,vec2(0.0),vec2(1.0));
    vec4 climate=textureLod(season_climate_map,uv,0.0);
    return vec2(climate.g,climate.r);
}

// Autumn ramp by how far the leaves have fallen (season_leaf_drop steps once a day, 0 on the
// first autumn day to 0.7 on the last): green-gold, orange-red, brown.
vec3 vegetation_autumn_colour(float t) {
    vec3 early=vec3(.74,.72,.2);
    vec3 mid=vec3(1.0,.38,.07);
    vec3 late=vec3(.52,.31,.15);
    return t<.5 ? mix(early,mid,t*2.0) : mix(mid,late,t*2.0-1.0);
}
// Autumn variety (dev 2026-11-10: every tree was the same dull brown). Before, every tree sat on
// the same point of one ramp and a turned leaf kept the darkness of the green leaf it had been,
// so orange came out brown. Now each tree has its own kind (yellow, orange or red), turns at its
// own time, and a turned leaf is lighter than a green one, as gold leaves are. A few trees stay
// mostly green. 0.0 here brings the old single ramp back.
const float LOOK_AUTUMN_VARIETY = 1.0;
// For callers with no tree (small plants): a middling orange kind.
const vec3 VEGETATION_NO_TREE = vec3(.5,.5,0.0);
// What kind of tree this is in autumn, from its root (the same root gives the same answer on the
// leaf cards, the impostor and the far crown): x = how late it turns (0 first, 1 last), y = its
// colour kind, z = 1 on the few that stay mostly green.
vec3 vegetation_autumn_tree(vec3 root) {
    uint v=uint(int(floor(root.x*4.0)))*73856093u^uint(int(floor(root.z*4.0)))*19349663u;
    v=v*747796405u+2891336453u;
    uint w=((v>>((v>>28u)+4u))^v)*277803737u;
    w=(w>>22u)^w;
    float late=float(w>>8u)/16777215.0;
    float kind=fract(late*61.37+.19);
    float stays=step(fract(late*173.3+.61),.07);
    return vec3(late,kind,stays);
}
// One kind of tree through its autumn, t 0..1: rgb and how much lighter than the green leaf (a).
vec4 vegetation_autumn_kind(float t,float kind) {
    vec3 early; vec3 mid; vec3 late; vec2 lift;
    // Yellow needs the most light: a dark yellow is olive, a dark orange brown (first shots).
    if (kind<.38) { early=vec3(.86,.80,.20); mid=vec3(1.0,.70,.10); late=vec3(.96,.55,.10); lift=vec2(1.9,1.6); }
    else if (kind<.74) { early=vec3(.92,.70,.16); mid=vec3(1.0,.42,.06); late=vec3(.86,.31,.07); lift=vec2(1.6,1.35); }
    else { early=vec3(.92,.52,.14); mid=vec3(.92,.17,.07); late=vec3(.60,.13,.09); lift=vec2(1.3,1.1); }
    vec3 c=t<.5 ? mix(early,mid,t*2.0) : mix(mid,late,t*2.0-1.0);
    return vec4(c,mix(lift.x,lift.y,t));
}
// Season tint for a leaf colour. green = how green the source pixel is (vegetation_green_mask);
// deciduous = vegetation_season_local().x. Evergreens use the contract's cold pine green.
// vary (about -.15..+.15) moves one card along its tree's autumn so a crown is not one flat
// colour; tree = vegetation_autumn_tree(root), or VEGETATION_NO_TREE.
// Outside the warm autumn palette the target is the season palette (spring green, winter grey).
vec3 vegetation_season_tint_tree(vec3 c,float green,float deciduous,bool is_evergreen,float vary,vec3 tree) {
    if (season_leaf.a<=.001) return c;
    if (is_evergreen) return season_leaf_tint(c,green,true);
    vec3 luma=vec3(.2126,.7152,.0722);
    float warm=smoothstep(.1,.3,season_leaf.r-season_leaf.g);
    vec3 target=season_leaf.rgb;
    float lift=1.0;
    float on=1.0;
    if (warm>0.0) {
        if (LOOK_AUTUMN_VARIETY>.5) {
            // This card's own autumn. season_leaf_turn runs 0 on the first day to 1 on the day
            // before the leaves fall: the first trees start at once, the last ones a third of the
            // way in, all are in full colour through the middle, and over the last third every
            // tree goes brown, fully brown at 1 (dev 2026-11-10).
            float own=season_leaf_turn*2.2-tree.x*.7+vary;
            vec4 kind=vegetation_autumn_kind(clamp(own,0.0,1.0),tree.y);
            float brown=smoothstep(.62,.9,season_leaf_turn+(tree.x-.5)*.12+vary*.4);
            kind=mix(kind,vec4(mix(vec3(.47,.29,.13),kind.rgb,.2),1.05),brown);
            target=mix(target,kind.rgb,warm);
            lift=mix(1.0,kind.a,warm);
            on=mix(1.0,smoothstep(-.05,.2,own)*mix(1.0,.35,tree.z),warm);
        } else {
            target=mix(target,vegetation_autumn_colour(clamp(season_leaf_turn+vary,0.0,1.0)),warm);
        }
    }
    vec3 turned=target*(dot(c,luma)/max(dot(target,luma),.00001))*lift;
    return mix(c,turned,clamp(season_leaf.a*green*deciduous*on,0.0,1.0));
}
vec3 vegetation_season_tint(vec3 c,float green,float deciduous,bool is_evergreen,float vary) {
    return vegetation_season_tint_tree(c,green,deciduous,is_evergreen,vary,VEGETATION_NO_TREE);
}

// Crown snow: the upper hemisphere of the crown normal (up = world normal y) whitens with the
// snow cover times the biome's snow response; the sides and underside stay leaf-coloured.
float vegetation_crown_snow_amount(float up,float snow_climate) {
    if (season_snow_cover<=.001) return 0.0;
    return clamp(season_snow_cover*snow_climate*smoothstep(.1,.75,up),0.0,1.0)*.9;
}
vec3 vegetation_crown_snow(vec3 c,float up,float snow_climate) {
    return season_snow_albedo(c,vegetation_crown_snow_amount(up,snow_climate));
}

// Stable hashes (PCG): the same input gives the same 0..1 value on every vertex and every frame.
float vegetation_hash(uint v) {
    v=v*747796405u+2891336453u;
    uint w=((v>>((v>>28u)+4u))^v)*277803737u;
    w=(w>>22u)^w;
    return float(w>>8u)/16777215.0;
}
// A per-tree seed from its root (4 per metre), so instances of one species thin differently.
uint vegetation_seed(vec3 root) {
    return uint(int(floor(root.x*4.0)))*73856093u^uint(int(floor(root.z*4.0)))*19349663u;
}
// Hash of the world cell (cell metres) around p: used where there are no cards (far crowns,
// native atlases) so whole patches of leaves go together.
float vegetation_cell_hash(vec3 p,float cell) {
    ivec3 c=ivec3(floor(p/max(cell,.001)));
    return vegetation_hash(uint(c.x)*73856093u^uint(c.y)*19349663u^uint(c.z)*83492791u);
}

// 1 = this leaf (card, patch or impostor texel) is still on the tree, 0 = it has fallen.
// overlap: about how many leaf layers cover a point of the crown. The hash is raised to it so the
// crown's visible coverage falls about linearly with the leaf drop: dropping 85% of cards that
// overlap 25 deep would otherwise still look full. Evergreens and deciduous share 0 keep every
// leaf; blossom trees (blossom = blossom_tree) keep cards as their blossom comes in spring.
// A card dropped on one day stays dropped on every later day of the same drop curve.
float vegetation_leaf_kept(float card_hash,float overlap,float deciduous,bool is_evergreen,float blossom) {
    if (season_leaf_drop<=.001 || is_evergreen) return 1.0;
    float scale=deciduous*(1.0-season_blossom*clamp(blossom,0.0,1.0));
    if (scale<=.001) return 1.0;
    return season_leaf_kept(pow(card_hash,max(overlap,1.0))/scale);
}

// Older all-in-one (ground hue, season tint at full deciduous share, flat winter wash). The tree
// shaders now use the pieces above; this stays for any outside caller.
vec3 vegetation_hue(vec3 authored,vec4 ground,float strength) {
    vec3 c=vegetation_ground_hue(authored,ground,strength);
    c=vegetation_season_tint(c,vegetation_green_mask(authored),1.0,false,0.0);
    return mix(c,vec3(.92,.94,.98),season_snow*.22);
}
// ------------------------------------------------------------------ spring (dev 2026-11-10)
// "we need pink trees, blossoming over time, leaves growing each day slowly over time that you
// can see over the course of a week or so". Each tree has its own spring from season_spring (the
// season's day ramp) and the per-tree numbers of vegetation_autumn_tree:
// - most of the broadleaf trees flower (SPRING_BLOSSOM_SHARE; a blossom_tree material always
//   does): buds over the whole bare crown as Winter Wrap Up ends, full bloom a few days later,
//   in flower for most of the season, then over about four days the whole crown turns from
//   blossom through a pale cream to young leaf as the petals fall. Three kinds: cherry pink, apple white, plum deep pink.
// - the others leaf out from the end of Winter Wrap Up over about a week of a 20-day spring.
// - every leaf is a light yellow green until the last days of spring, so a spring tree is never
//   a summer tree (dev 2026-11-10: "shouldnt the trees be different in spring vs summer?").
// A crown always grows as a whole: every spray of it is there from the first day, small, and
// all of them grow together. Never sprays switched on one by one or leaf eaten away in patches:
// that left crowns "broken apart with holes in them" (dev 2026-11-10, and the rule of 2026-11-09).
// Trees stand up to two days apart (their `late` number), so the valley does not move as one.
// LOOK_SPRING = 0.0 restores the old spring: full crowns the day Winter Wrap Up ends and blossom
// only on blossom_tree materials, by season_blossom.
const float LOOK_SPRING = 1.0;
const float SPRING_BLOSSOM_SHARE = .6;
// x = this tree's leaf growth today (0 bare .. 1 full crown), y = how far its blossom has opened
// (0 on a tree that does not flower, or not yet), z = its blossom kind 0..1, w = how much of its
// blossom has fallen (1 = none left).
// tree = vegetation_autumn_tree(root); own_blossom = the material's blossom_tree.
vec4 vegetation_spring_tree(vec3 tree,float own_blossom) {
    if (season_spring<=.0005 || LOOK_SPRING<=0.0 || evergreen) return vec4(1.0,0.0,0.0,1.0);
    float late=tree.x;
    bool flowers=own_blossom>.5 || fract(late*97.13+.37)<SPRING_BLOSSOM_SHARE;
    float off=late*.1;
    float open=flowers ? smoothstep(.13+off,.30+off,season_spring) : 0.0;
    float gone=flowers ? smoothstep(.68+off,.86+off*.6,season_spring) : 1.0;
    float start=flowers ? .5+off : .2+late*.08;
    return vec4(clamp((season_spring-start)/.38,0.0,1.0),open,fract(late*41.7+.11),gone);
}
// Is this tree's crown still growing or in flower today (else it is a plain summer crown).
bool vegetation_spring_active(vec4 spring) {
    return spring.x<.999 || (spring.y>0.0 && spring.w<1.0);
}
// How much one spray of the crown (its own number h 0..1) is in flower: all of them while the
// tree blooms, then the whole crown goes over together as the petals fall, a spray at most a
// little ahead of or behind its neighbours. Never spray by spray: a crown half pink sprays and
// half green ones "looks so dogshit" (dev 2026-11-10); the crown turns as one, as a real cherry
// does from far off (vegetation_blossom_tree gives the colours on the way).
float vegetation_spring_flower(vec4 spring,float h) {
    if (spring.y<=0.0 || spring.w>=1.0) return 0.0;
    float f=1.0-spring.w;
    return clamp(f+(h-.5)*.5*f*(1.0-f),0.0,1.0);
}
// The size of a spray today, as a share of its summer size (0 = nothing on the tree yet): leaf
// from a bud to full, blossom from a bud to a little fuller than the leaf it will be.
float vegetation_spring_size(vec4 spring,float flower) {
    float leaf=spring.x>0.0 ? mix(.45,1.0,smoothstep(0.0,.75,spring.x)) : 0.0;
    float bloom=spring.y>0.0 ? mix(.55,1.12,smoothstep(0.0,.6,spring.y)) : 0.0;
    return mix(leaf,bloom,flower);
}
// The colour of a blossom kind (vegetation_spring_tree z).
vec3 vegetation_blossom_kind(float kind) {
    if (kind<.5) return vec3(.90,.47,.62);
    if (kind<.8) return vec3(.90,.76,.80);
    return vec3(.86,.30,.54);
}
// Blossom of this kind over a leaf colour (on = 0..1), bright whatever leaf it covers; vary (about
// -0.15..0.15) tells neighbouring sprays apart. As the blossom goes over (on 1 -> 0) the colour
// runs blossom -> nearly white (a cherry's petals pale before they fall) -> the young leaf.
// Mixed straight, pink and green met in a dull tan; through a peach gold the crown stood beige
// for a day (shots of 2026-11-10). The pale stop needs the crown's own light and a light young
// leaf under it (vegetation_spring_light, vegetation_spring_young), or it greys in the shade.
vec3 vegetation_blossom_tree(vec3 c,float on,float kind,float vary) {
    if (on<=0.0) return c;
    float value=clamp(dot(c,vec3(.2126,.7152,.0722))/.3,.8,1.0)*(1.0+vary*.5);
    vec3 pink=vegetation_blossom_kind(kind)*value;
    vec3 pale=mix(pink,vec3(.97,.95,.82)*value,.8);
    return on>.5 ? mix(pale,pink,smoothstep(.5,1.0,on)) : mix(c,pale,smoothstep(0.0,.5,on));
}
// How young a leaf is today, 0..1 (0 outside spring, on evergreens and where nothing is
// deciduous): 1 all spring, most of the way down over the season's last three days.
// Any leaf that is at all green counts whole: the blue-green kinds have a low green mask and
// stayed dark teal beside the yellow-green ones (shots of 2026-11-10).
float vegetation_spring_fresh(float green,float deciduous) {
    if (season_spring<=.0005 || LOOK_SPRING<=0.0 || evergreen || deciduous<=.001) return 0.0;
    return (1.0-.85*smoothstep(.88,1.0,season_spring))*smoothstep(0.0,.3,green)*smoothstep(0.0,.25,deciduous);
}
// Young leaves: a light yellow green all spring, twice as light as the summer leaf (at 1.3 a
// young crown was the summer crown a shade yellower and still read as a summer tree).
vec3 vegetation_spring_young(vec3 c,float green,float deciduous) {
    float fresh=vegetation_spring_fresh(green,deciduous);
    if (fresh<=0.0) return c;
    vec3 luma=vec3(.2126,.7152,.0722);
    vec3 young=vec3(.58,.88,.2);
    return mix(c,young*min(dot(c,luma)/dot(young,luma)*2.2,1.0),fresh*.92);
}
// A spring crown's own light (EMISSION) by day: c = its finished colour, on = how much it is in
// flower. Half of a crown faces away from the sun and is lit by the blue sky alone: there pink
// blossom read lilac, the gold of a crown going over and the yellow green of young leaf read
// grey teal (shots of 2026-11-10). A third of the blossom's colour and a seventh of a young
// leaf's, a little warm, holds them. Nothing at night (sky_daylight, world/sky_controller.gd).
vec3 vegetation_spring_light(vec3 c,float on,float green,float deciduous) {
    float amount=max(.32*smoothstep(0.0,.15,on),.14*vegetation_spring_fresh(green,deciduous));
    return c*vec3(1.0,.9,.8)*(amount*sky_daylight);
}
// The native cel-shaded atlases (world/foliage/shaders/cel-shader-*): one band colour c through
// ground hue (strength already scaled by the leaf mask), season tint and crown snow (amount from
// vegetation_crown_snow_amount with the fragment's world normal).
vec3 vegetation_cel(vec3 c,vec4 ground,float strength,vec2 local,float snow,vec3 tree) {
    float green=vegetation_green_mask(c);
    c=vegetation_ground_hue(c,ground,strength);
    c=vegetation_season_tint_tree(c,green,local.x,evergreen,0.0,tree);
    c=vegetation_spring_young(c,green,local.x);
    return season_snow_albedo(c,snow);
}

// ------------------------------------------------------------------ winter twigs (2026-11-09)
// Bare-branch pictures that take a leaf's place as it falls, so a winter crown reads as twigs
// instead of empty space. A 2x2 atlas (built by build_twigs.py in the private art folder, winter-twigs-2026-11-09):
// each cell a spray from its bottom centre fanning out inside the inscribed circle (cards turn
// the picture freely). RGB = grey shade (sRGB), A = cover. Read only while season_leaf_drop >
// 0.001: summer never samples it.
global uniform sampler2D vegetation_twig_atlas : source_color, filter_linear_mipmap, repeat_disable;
// Per material: the twigs' bark colour (multiplies the atlas shade).
uniform vec4 twig_color : source_color = vec4(0.34, 0.3, 0.27, 1.0);

// Twig picture `variant` (0..3) at cell uv (0..1, v down); duv_dx/duv_dy = screen derivatives of
// uv taken in uniform control flow. rgb = twig colour, a = cover, 0 outside the cell. Thin twigs
// fade away in small mips, so the cover is raised by `boost` per mip level (a * (1 + lod * boost)).
// dev 2026-11-09 ("reads as tile grids"): twigs are off; bare trees show trunk and limbs only.
const bool VEGETATION_TWIGS = false;
vec4 vegetation_twig(vec2 uv, vec2 duv_dx, vec2 duv_dy, float variant, float boost) {
	if (!VEGETATION_TWIGS) return vec4(0.0);
	vec2 cell_px = vec2(textureSize(vegetation_twig_atlas, 0)) * 0.5;
	vec2 dx = duv_dx * cell_px;
	vec2 dy = duv_dy * cell_px;
	float lod = clamp(0.5 * log2(max(max(dot(dx, dx), dot(dy, dy)), 1e-8)), 0.0, 5.0);
	vec2 cell = vec2(mod(variant, 2.0), floor(variant * 0.5));
	vec4 t = textureLod(vegetation_twig_atlas, (cell + clamp(uv, vec2(0.0), vec2(1.0))) * 0.5, lod);
	float inside = step(0.0, uv.x) * step(uv.x, 1.0) * step(0.0, uv.y) * step(uv.y, 1.0);
	return vec4(t.rgb * twig_color.rgb, clamp(t.a * (1.0 + lod * boost), 0.0, 1.0) * inside);
}

// Snow on the upper side of the twigs: 1 where nothing of the twig lies just above this texel.
// up = world up as a direction in the picture's uv (not normalised: its length is how much of
// world up the view shows, 0 looking straight up or down).
float vegetation_twig_snow_edge(vec2 uv, vec2 duv_dx, vec2 duv_dy, float variant, float boost, vec2 up) {
	float l = length(up);
	if (l < 0.05) return 0.5;
	float step_uv = max(1.5 * max(length(duv_dx), length(duv_dy)), 2.0 / 512.0);
	float above = vegetation_twig(uv + up / l * step_uv, duv_dx, duv_dy, variant, boost).a;
	return 1.0 - above;
}

// Twig lace for pictures without cards (impostors, far crowns, native atlases): two staggered
// grids of upright twig pictures over q (one picture per unit cell), each cell its own variant and
// mirror, the denser of the two kept, so it reads as interlaced branches rather than a grid.
// dqx/dqy = screen derivatives of q taken in uniform control flow.
vec4 vegetation_twig_lace(vec2 q, vec2 dqx, vec2 dqy, uint seed, float boost) {
	vec4 best = vec4(0.0);
	for (int layer = 0; layer < 2; layer++) {
		vec2 p = q + (layer == 0 ? vec2(0.0) : vec2(0.5, 0.43));
		vec2 id = floor(p);
		float h = vegetation_hash(uint(int(id.x)) * 73856093u ^ uint(int(id.y)) * 19349663u ^ (seed + uint(layer) * 2654435761u));
		vec2 uv = p - id;
		if (h > 0.5) uv.x = 1.0 - uv.x;
		vec4 t = vegetation_twig(uv, dqx, dqy, floor(fract(h * 7.0) * 4.0), boost);
		if (t.a > best.a) best = t;
	}
	return best;
}

// Twig lace laid on a surface by world position (far crowns, the native atlases): the normal's
// dominant axis picks the plane, `cell` metres per picture, twigs growing upward on the sides.
// dpdx/dpdy = screen derivatives of p taken in uniform control flow.
vec4 vegetation_twig_world(vec3 p, vec3 dpdx, vec3 dpdy, vec3 n, float cell, float boost) {
	vec3 a = abs(n);
	bool top = a.y > max(a.x, a.z);
	bool side_x = a.x > a.z;
	vec2 q = top ? p.xz : (side_x ? vec2(p.z, -p.y) : vec2(p.x, -p.y));
	vec2 qx = top ? dpdx.xz : (side_x ? vec2(dpdx.z, -dpdx.y) : vec2(dpdx.x, -dpdx.y));
	vec2 qy = top ? dpdy.xz : (side_x ? vec2(dpdy.z, -dpdy.y) : vec2(dpdy.x, -dpdy.y));
	return vegetation_twig_lace(q / cell, qx / cell, qy / cell, top ? 7u : (side_x ? 3u : 0u), boost);
}

// 1 while the trees stand bare in winter: leaves mostly down and the palette neither the warm
// autumn one nor the fresh spring green (so autumn's last days and spring's regrowth are 0).
float vegetation_bare_winter() {
	float warm = smoothstep(.1, .3, season_leaf.r - season_leaf.g);
	float fresh = smoothstep(.05, .2, season_leaf.g - season_leaf.r);
	return (1.0 - warm) * (1.0 - fresh) * smoothstep(.6, .8, season_leaf_drop);
}
// The last leaves left on a bare winter tree are dead brown ones.
vec3 vegetation_dead_leaves(vec3 c) {
	float bare = vegetation_bare_winter();
	if (bare <= 0.0) return c;
	vec3 brown = vegetation_autumn_colour(1.0);
	vec3 luma = vec3(.2126, .7152, .0722);
	return mix(c, brown * (dot(c, luma) / dot(brown, luma)), bare * .85);
}
// How much of a leaf card's leaves are still on (1 = all, 0 = none): the card's leaves thin in soft
// patches over the last `band` of drop before the card falls. life = the card's raised hash over
// its deciduous scale (vegetation_leaf_life); summer (drop 0) keeps everything. Once the palette
// is the winter one and the trees are bare (vegetation_bare_winter), the few cards still on keep
// only a scatter of dead leaves on their twigs.
float vegetation_leaf_amount(float life) {
	if (season_leaf_drop <= .001) return 1.0;
	float band = clamp(season_leaf_drop, .001, .12);
	return clamp((life - season_leaf_drop) / band, 0.0, 1.0) * (1.0 - vegetation_bare_winter() * .85);
}
// The leaf life of a card (compare with season_leaf_drop: kept while life >= drop). Same rule as
// vegetation_leaf_kept; 2 for cards that never fall.
float vegetation_leaf_life(float card_hash, float overlap, float deciduous, bool is_evergreen, float blossom) {
	if (season_leaf_drop <= .001 || is_evergreen) return 2.0;
	float scale = deciduous * (1.0 - season_blossom * clamp(blossom, 0.0, 1.0));
	if (scale <= .001) return 2.0;
	return pow(card_hash, max(overlap, 1.0)) / scale;
}
// Far pictures (impostors, far crowns, native atlases) keep a share of leaf patches through the
// drop; on a bare winter tree nearly all of them go to twigs too, like the near cards' leaves.
float vegetation_patch_kept(float kept, float patch_hash, float deciduous, bool is_evergreen) {
	if (kept < 0.5) return 0.0;
	if (is_evergreen || deciduous <= .001) return 1.0;
	return step(vegetation_bare_winter() * 0.9, fract(patch_hash * 31.0));
}
// Soft value-noise patches over a card (0..1) for leaves thinning on it.
float vegetation_leaf_patch(vec2 uv, float seed) {
	vec2 p = uv * 4.0;
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	uint s = uint(seed * 65535.0);
	float a = vegetation_hash(uint(int(i.x)) * 73856093u ^ uint(int(i.y)) * 19349663u ^ s);
	float b = vegetation_hash(uint(int(i.x) + 1) * 73856093u ^ uint(int(i.y)) * 19349663u ^ s);
	float c = vegetation_hash(uint(int(i.x)) * 73856093u ^ uint(int(i.y) + 1) * 19349663u ^ s);
	float d = vegetation_hash(uint(int(i.x) + 1) * 73856093u ^ uint(int(i.y) + 1) * 19349663u ^ s);
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}
// Soft clouds 0..1 from value noise over q (about one cloud per four units), not square cells:
// the square cells of the old blossom read as tiles (shots of 2026-11-10).
float vegetation_spring_cloud(vec2 q,float seed) {
    return smoothstep(.22,.78,vegetation_leaf_patch(q*.25,seed)*.65+vegetation_leaf_patch(q*.25*2.7+vec2(3.1,7.7),seed)*.35);
}
// Far pictures (impostors, far crowns) of a tree in spring. q = a picture or world coordinate
// with about one small spray of leaves per unit. x = 1 where the crown has leaf or blossom today
// (else its twigs show), y = how much that point is in flower.
// The near tree's sprays are all there but small; far off the same crown is a fine even speckle
// of leaf over its twigs, as dense as the small sprays cover it (about eight overlap in summer).
vec2 vegetation_spring_far(vec4 spring,vec2 q,float seed) {
    float flower=vegetation_spring_flower(spring,.5);
    float size=vegetation_spring_size(spring,flower);
    float cover=1.0-exp(-8.0*size*size);
    return vec2(step(vegetation_leaf_patch(q*.25+vec2(11.0,5.0),seed),cover*1.05)*step(.001,size),flower);
}
// Snow lying on twigs: the snow cover times the biome's response, less low in the crown and seen
// from below (looking up shows the bare undersides).
float vegetation_twig_snow(float crown_up, float snow_climate, float look_up) {
	if (season_snow_cover <= .001) return 0.0;
	float s = season_snow_cover * snow_climate * mix(.55, 1.0, smoothstep(-.3, .6, crown_up));
	return clamp(s * clamp(1.0 - max(look_up, 0.0) * 1.3, .15, 1.0), 0.0, 1.0) * .95;
}
#endif
