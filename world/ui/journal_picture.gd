extends Node
## A journal page (world/ui/journal_page.gd) drawn as a picture to share (dev 2026-10-28: "a cool
## format to show to others"): the logo, the world and who was there on top, then the talk as chat
## bubbles (ponies on the left with their cutie mark, the player on the right) or as a script, and
## the moments in between. Eleven pony looks, three widths, three text sizes, and every part can be
## left out (dev 2026-10-28: "more log styles, allow option to remove the logo, date and such"); the
## choices are kept in user://journal_picture.cfg. Laid out once in an off-screen SubViewport at its
## final pixels; a long talk comes out as several even pages cut between rows.
## Usage: add it to the tree, `await picture.render(spec)` -> Array[Image], then free it.
const STYLE := preload("res://world/ui/menu_style.gd")
const ICON := preload("res://world/ui/menu_icon.gd")
const DATA := preload("res://world/ui/journal_data.gd")
const PONY_DATA := preload("res://world/ui/pony_map_data.gd")
const OVERHEAD := preload("res://world/ai/overhead_dialogue.gd")
const LOGO := preload("res://world/ui/title/logo.png")
const OPTIONS_PATH := "user://journal_picture.cfg"
## What a picture shows and how; the studio (journal_page.gd) edits these.
const DEFAULTS := {"look": "twilight", "layout": "bubbles", "width": "standard", "text": "medium", "title": "",
	"logo": true, "world": true, "when": true, "cast": true, "headings": true, "times": true, "addressee": true,
	"moments": true, "portraits": true, "footer": true, "date": true}
const WIDTHS := {"phone": 900, "standard": 1280, "wide": 1600}
const TEXT_SCALES := {"small": 0.86, "medium": 1.0, "large": 1.18}
const TOP := 64
const BOTTOM := 56
## Pages are cut between rows once a picture would be taller than this.
const PAGE_HEIGHT := 3600
const TEXT_SIZE := 25
const NAME_SIZE := 27
const PORTRAIT := 62
const CAST_SHOWN := 8
## [key, name, pony whose cutie mark stands for it ("" = its icon), icon] in the studio's order.
## Dev 2026-10-28: "make it pony based instead ... the mane6 and the two princesses + other".
const LOOK_NAMES := [["twilight", "Twilight", "twilight_sparkle", "sparkle"], ["rarity", "Rarity", "rarity", "gem"],
	["applejack", "Applejack", "applejack", "apple"], ["rainbow_dash", "Rainbow Dash", "rainbow_dash", "cloud"],
	["pinkie_pie", "Pinkie Pie", "pinkie_pie", "cupcake"], ["fluttershy", "Fluttershy", "fluttershy", "butterfly"],
	["celestia", "Celestia", "", "sun"], ["luna", "Luna", "", "moon"], ["spike", "Spike", "", "quill"],
	["zecora", "Zecora", "", "potion"], ["trixie", "Trixie", "trixie", "star_filled"]]
## Looks of earlier versions, kept in user://journal_picture.cfg, and the pony each became.
const OLD_LOOKS := {"parchment": "spike", "daylight": "rainbow_dash", "candy": "pinkie_pie", "everfree": "zecora", "midnight": "luna"}
## Each look: the ink, the bubbles (`rim`: how strongly a pony's colour rims hers; `mine`: the
## player's), `me` the player's name and the title, `icon` the ornament, and the backdrop: a gradient,
## two soft lights and a motif (stars or fireflies, diamonds, gingham, a rainbow streak, confetti,
## bokeh, the sun, the moon, a spotlight, zebra stripes and mudcloth borders, clouds, paper).
## `dark` picks lifted or deepened names.
const LOOKS := {
	"twilight": {"top": Color("2b1b47"), "bottom": Color("110a1f"), "text": STYLE.CREAM, "muted": STYLE.MUTED, "faint": STYLE.FAINT,
		"bubble": Color("2c1d45"), "rim": 0.5, "mine": Color("432a66"), "mine_rim": Color(STYLE.LILAC, 0.75), "me": Color("e3a8f0"),
		"moment": STYLE.BUTTER, "rule": Color(1, 1, 1, 0.13), "dark": true, "icon": "sparkle",
		"glow_a": Color(0.55, 0.3, 0.75, 0.11), "glow_b": Color(0.95, 0.45, 0.7, 0.07), "stars": 1.0, "star": Color("fff0fa")},
	"rarity": {"top": Color("faf6fd"), "bottom": Color("e7dcf3"), "text": Color("2b1f45"), "muted": Color("5d4d7c"), "faint": Color("9284ad"),
		"bubble": Color(1, 1, 1, 0.94), "rim": 0.6, "mine": Color("e6ddfa"), "mine_rim": Color("6a59b8"), "me": Color("4f3f9e"),
		"moment": Color("6a59b8"), "rule": Color(0.3, 0.2, 0.5, 0.16), "dark": false, "icon": "gem",
		"glow_a": Color(1, 1, 1, 0.4), "glow_b": Color(0.85, 0.7, 1, 0.2), "diamonds": 1.0, "motif": Color("8e7cc8"),
		"stars": 0.8, "star": Color("ffffff"), "star_size": 2.2},
	"applejack": {"top": Color("fff4e0"), "bottom": Color("f6d6a3"), "text": Color("452812"), "muted": Color("744c2c"), "faint": Color("a8805c"),
		"bubble": Color("fffaf1"), "rim": 0.6, "mine": Color("ffe2b3"), "mine_rim": Color("e3832a"), "me": Color("b0501a"),
		"moment": Color("b23a2a"), "rule": Color(0.4, 0.22, 0.1, 0.18), "dark": false, "icon": "apple",
		"glow_a": Color(1, 0.95, 0.85, 0.3), "glow_b": Color(1, 0.75, 0.45, 0.15), "gingham": 1.0, "motif": Color("d9503f")},
	"rainbow_dash": {"top": Color("7cc6f4"), "bottom": Color("e2f4ff"), "text": Color("1b2a46"), "muted": Color("3a5076"), "faint": Color("6a83a8"),
		"bubble": Color(1, 1, 1, 0.93), "rim": 0.6, "mine": Color("e3f3ff"), "mine_rim": Color("2b8ee0"), "me": Color("1d6bc0"),
		"moment": Color("d8402c"), "rule": Color(0.1, 0.2, 0.4, 0.18), "dark": false, "icon": "cloud",
		"glow_a": Color(1, 1, 1, 0.3), "glow_b": Color(1, 1, 1, 0.2), "clouds": 1.0, "rainbow": 1.0},
	"pinkie_pie": {"top": Color("ffe3f2"), "bottom": Color("ffc6e4"), "text": Color("4a1f3d"), "muted": Color("7a3d66"), "faint": Color("ad7799"),
		"bubble": Color("fff8fc"), "rim": 0.6, "mine": Color("fbd0ec"), "mine_rim": Color("e45aa8"), "me": Color("b02c7a"),
		"moment": Color("c93c8a"), "rule": Color(0.45, 0.12, 0.35, 0.18), "dark": false, "icon": "cupcake",
		"glow_a": Color(1, 1, 1, 0.35), "glow_b": Color(1, 0.95, 0.75, 0.2), "confetti": 1.0},
	"fluttershy": {"top": Color("fffbe2"), "bottom": Color("fde2ee"), "text": Color("463826"), "muted": Color("6f6150"), "faint": Color("a39782"),
		"bubble": Color("fffef7"), "rim": 0.55, "mine": Color("ffe2ee"), "mine_rim": Color("ee96bd"), "me": Color("bd5486"),
		"moment": Color("4c9566"), "rule": Color(0.3, 0.3, 0.15, 0.16), "dark": false, "icon": "butterfly",
		"glow_a": Color(1, 1, 0.9, 0.35), "glow_b": Color(1, 0.85, 0.92, 0.25), "bokeh": 1.0},
	"celestia": {"top": Color("fff6dc"), "bottom": Color("f6cbd9"), "text": Color("382816"), "muted": Color("6b543d"), "faint": Color("a28b70"),
		"bubble": Color(1, 1, 1, 0.9), "rim": 0.6, "mine": Color("dff3f1"), "mine_rim": Color("45aaa2"), "me": Color("2a8780"),
		"moment": Color("bb8410"), "rule": Color(0.45, 0.3, 0.1, 0.18), "dark": false, "icon": "sun",
		"glow_b": Color(0.6, 0.85, 0.9, 0.2), "sun": 1.0, "motif": Color("ffd77a")},
	"luna": {"top": Color("101a3e"), "bottom": Color("05081a"), "text": Color("e8edff"), "muted": Color("aab5dc"), "faint": Color("7480aa"),
		"bubble": Color("16204a"), "rim": 0.5, "mine": Color("27356f"), "mine_rim": Color("8ea6ff"), "me": Color("aabdff"),
		"moment": Color("c9d5ff"), "rule": Color(0.8, 0.85, 1, 0.13), "dark": true, "icon": "moon",
		"glow_a": Color(0.35, 0.4, 0.8, 0.12), "glow_b": Color(0.3, 0.25, 0.6, 0.08), "stars": 1.0, "star": Color("e2eaff"),
		"moon": 1.0, "motif": Color("f0f3ff")},
	"spike": {"top": Color("fbf4e6"), "bottom": Color("efdfc2"), "text": Color("2c1f3b"), "muted": Color("5e4d70"), "faint": Color("917f9f"),
		"bubble": Color(1, 1, 1, 0.72), "rim": 0.55, "mine": Color("eadcf6"), "mine_rim": Color("9d6fd0"), "me": Color("7a3fa6"),
		"moment": Color("3d8a36"), "rule": Color(0.24, 0.15, 0.3, 0.16), "dark": false, "icon": "quill", "grain": 1.0,
		"glow_b": Color(0.5, 0.85, 0.4, 0.08)},
	# Zecora's hut (dev 2026-10-28: "more of an Africa/voodoo vibe"): umber and ochre by firelight,
	# her stripes, mudcloth zigzags down both sides, gold like her rings, a potion's green glow and
	# rising embers.
	"zecora": {"top": Color("3b2318"), "bottom": Color("150b07"), "text": Color("f6ead8"), "muted": Color("d6bc98"), "faint": Color("9c8468"),
		"bubble": Color("2e1b11"), "rim": 0.5, "mine": Color("4a3312"), "mine_rim": Color("e2a93b"), "me": Color("f3c35a"),
		"moment": Color("8fe3b4"), "rule": Color(1, 0.85, 0.6, 0.15), "dark": true, "icon": "potion",
		"glow_a": Color(0.95, 0.5, 0.18, 0.12), "glow_b": Color(0.25, 0.9, 0.55, 0.14), "stars": 0.8, "star": Color("ffb35c"), "star_size": 2.4,
		"zebra": 1.0, "mudcloth": 1.0, "motif": Color("d39a4a")},
	"trixie": {"top": Color("1e2b6e"), "bottom": Color("0c1132"), "text": Color("eef2ff"), "muted": Color("b3bde6"), "faint": Color("7b86b6"),
		"bubble": Color("1f2b64"), "rim": 0.5, "mine": Color("3a4fa8"), "mine_rim": Color("8cc8ff"), "me": Color("9fd6ff"),
		"moment": Color("ffd36b"), "rule": Color(1, 1, 1, 0.13), "dark": true, "icon": "star_filled",
		"glow_a": Color(0.5, 0.4, 0.9, 0.12), "glow_b": Color(0.3, 0.6, 1, 0.08), "stars": 1.0, "star": Color("ffffff"), "star_size": 2.0,
		"spotlight": 1.0},
}
const BACKDROP := """
shader_type canvas_item;
uniform vec2 size_px = vec2(1280.0, 2000.0);
uniform vec2 offset_px = vec2(0.0);
uniform vec4 top_color : source_color;
uniform vec4 bottom_color : source_color;
uniform vec4 glow_a : source_color = vec4(0.0);
uniform vec4 glow_b : source_color = vec4(0.0);
uniform vec4 motif : source_color = vec4(1.0);
uniform float stars = 0.0;
uniform vec4 star_color : source_color = vec4(1.0);
uniform float star_size = 1.5;
uniform float confetti = 0.0;
uniform float clouds = 0.0;
uniform float grain = 0.0;
uniform float diamonds = 0.0;
uniform float gingham = 0.0;
uniform float rainbow = 0.0;
uniform float bokeh = 0.0;
uniform float sun = 0.0;
uniform float moon = 0.0;
uniform float spotlight = 0.0;
uniform float zebra = 0.0;
uniform float mudcloth = 0.0;
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float noise(vec2 g) {
	vec2 f = fract(g); f = f * f * (3.0 - 2.0 * f);
	vec2 i = floor(g);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0)), f.x), f.y);
}
vec3 pastel(float pick) {
	return pick < 0.2 ? vec3(0.96, 0.55, 0.8) : pick < 0.4 ? vec3(0.55, 0.8, 0.95) : pick < 0.6 ? vec3(1.0, 0.86, 0.45) : pick < 0.8 ? vec3(0.56, 0.89, 0.76) : vec3(0.75, 0.6, 0.95);
}
void fragment() {
	vec2 px = UV * size_px;
	// Where this pixel is in the whole picture: the motifs carry on across pages.
	vec2 at = px + offset_px;
	float w = size_px.x;
	vec3 c = mix(top_color.rgb, bottom_color.rgb, clamp(px.y / size_px.y, 0.0, 1.0));
	// Two soft lights: high on the left, low on the right (alpha is their strength). Blended towards
	// their colour rather than added, so a pale look cannot wash out to white on a short page.
	c = mix(c, glow_a.rgb, clamp(glow_a.a * 2.0 * exp(-pow(distance(px / w, vec2(0.12, 0.08)) * 2.2, 2.0)), 0.0, 1.0));
	c = mix(c, glow_b.rgb, clamp(glow_b.a * 2.0 * exp(-pow(distance(px / w, vec2(0.9, size_px.y / w - 0.1)) * 2.0, 2.0)), 0.0, 1.0));
	// Celestia: the sun rising over the top, with slow rays.
	vec2 from_sun = at - vec2(w * 0.5, -80.0);
	float sd = length(from_sun);
	float rays = pow(abs(sin(atan(from_sun.y, from_sun.x) * 11.0)), 6.0);
	c = mix(c, motif.rgb, sun * clamp(0.75 * exp(-sd / 360.0) + 0.16 * rays * smoothstep(1300.0, 150.0, sd), 0.0, 0.85));
	// Trixie: a spotlight from the top of the stage.
	float cone = 140.0 + at.y * 0.32;
	c += spotlight * vec3(1.0, 0.95, 0.8) * 0.13 * smoothstep(cone, cone * 0.55, abs(at.x - w * 0.5)) * smoothstep(1600.0, 0.0, at.y);
	// Rainbow Dash: a slim rainbow arching over the top, above the logo, fading at its ends.
	float band = at.y - (8.0 + 160.0 * pow((at.x - w * 0.5) / (w * 0.5), 2.0));
	if (band > 0.0 && band < 42.0) {
		int stripe = int(band / 7.0);
		vec3 hue = stripe == 0 ? vec3(1.0, 0.42, 0.42) : stripe == 1 ? vec3(1.0, 0.66, 0.3) : stripe == 2 ? vec3(1.0, 0.88, 0.4) : stripe == 3 ? vec3(0.41, 0.86, 0.49) : stripe == 4 ? vec3(0.3, 0.67, 0.97) : vec3(0.69, 0.59, 0.99);
		c = mix(c, hue, rainbow * 0.6 * smoothstep(0.0, 0.18, at.x / w) * smoothstep(1.0, 0.82, at.x / w));
	}
	// Rarity: a fine diamond lattice.
	vec2 r = vec2(at.x + at.y, at.x - at.y) * 0.7071 / 64.0;
	vec2 q = (0.5 - abs(fract(r) - 0.5)) * 64.0;
	c = mix(c, motif.rgb, diamonds * 0.16 * smoothstep(1.2, 0.0, min(q.x, q.y)));
	// Applejack: gingham, the crossings darker.
	vec2 check = mod(floor(at / 30.0), 2.0);
	c = mix(c, motif.rgb, gingham * 0.055 * (check.x + check.y));
	// Luna: the crescent moon and its halo.
	vec2 mc = vec2(w * 0.84, 150.0);
	float md = distance(at, mc);
	float lit = smoothstep(58.0, 56.0, md) * smoothstep(48.0, 50.0, distance(at, mc + vec2(-24.0, -14.0)));
	c = mix(c, motif.rgb, moon * clamp(lit + 0.22 * exp(-md / 120.0), 0.0, 1.0));
	// Zecora: wavy zebra stripes, faint, over the whole picture.
	float stripe_wave = sin((at.x * 0.55 + at.y) / 30.0 + 1.8 * sin(at.x / 170.0 + at.y / 260.0));
	c = mix(c, vec3(0.96, 0.9, 0.8), zebra * 0.055 * smoothstep(0.45, 0.75, stripe_wave));
	// Zecora: mudcloth borders down both side margins and across the top: rails, a zigzag with
	// filled teeth on one side and dots in the pockets on the other.
	// At most 54 pixels: inside the 64-pixel top margin (TOP) and the side margins at every width.
	float strip = min(w * 0.05, 54.0);
	float across = min(min(at.x, w - at.x), at.y) / strip;
	if (across < 1.0) {
		// Along the border: down the sides, along the top.
		float along = min(at.x, w - at.x) < at.y ? at.y : at.x;
		float zig = 0.22 + 0.56 * abs(fract(along / 44.0) - 0.5) * 2.0;
		float ink = smoothstep(1.8, 0.5, abs(across - zig) * strip);
		ink = max(ink, smoothstep(1.6, 0.4, abs(across - 0.06) * strip));
		ink = max(ink, smoothstep(1.6, 0.4, abs(across - 0.94) * strip));
		// Teeth: the band between the outer rail and the zigzag, softly filled.
		ink = max(ink, 0.32 * step(0.06, across) * step(across, zig));
		float row = floor(along / 22.0);
		vec2 pocket = vec2((mod(row, 2.0) < 1.0 ? 0.8 : 0.66) * strip, (row + 0.5) * 22.0);
		ink = max(ink, smoothstep(3.0, 2.0, distance(vec2(across * strip, along), pocket)));
		// Where the top band meets a side one: a square of rails with a dot in it.
		vec2 corner = vec2(min(at.x, w - at.x), at.y) / strip;
		if (corner.x < 1.0 && corner.y < 1.0) {
			vec2 rail = min(abs(corner - 0.06), abs(corner - 0.94)) * strip;
			ink = max(smoothstep(1.6, 0.4, min(rail.x, rail.y)) * step(max(corner.x, corner.y), 0.97), smoothstep(7.0, 5.8, distance(corner, vec2(0.5)) * strip));
		}
		c = mix(c, motif.rgb, mudcloth * 0.62 * ink);
	}
	// Stars (or fireflies, bigger and haloed) on a 26-pixel grid, one cell in seven.
	vec2 cell = floor(at / 26.0);
	vec2 spot = (cell + vec2(hash(cell + 3.1), hash(cell + 7.7))) * 26.0;
	float d = distance(at, spot);
	float twinkle = step(0.86, hash(cell)) * (0.2 + 0.4 * hash(cell + 1.3));
	float star = twinkle * (smoothstep(star_size, 0.0, d) + (star_size > 2.0 ? 0.35 * exp(-d / star_size) : 0.0));
	c = mix(c, star_color.rgb, clamp(stars * star, 0.0, 1.0));
	// Pinkie Pie: confetti, little pastel dots, one cell in eight.
	vec2 bit = floor(at / 34.0);
	vec2 dot_at = (bit + vec2(0.2) + 0.6 * vec2(hash(bit + 2.3), hash(bit + 5.9))) * 34.0;
	c = mix(c, pastel(hash(bit + 9.1)), confetti * step(0.875, hash(bit)) * smoothstep(3.6, 2.6, distance(at, dot_at)) * 0.85);
	// Fluttershy: big soft pastel bokeh, each disc wholly inside its 150-pixel cell.
	vec2 blob = floor(at / 150.0);
	float radius = 20.0 + 26.0 * hash(blob + 6.6);
	vec2 blob_at = blob * 150.0 + radius + vec2(hash(blob + 4.4), hash(blob + 8.8)) * (150.0 - 2.0 * radius);
	c = mix(c, pastel(hash(blob + 1.7)), bokeh * step(0.55, hash(blob + 3.3)) * smoothstep(radius, radius * 0.6, distance(at, blob_at)) * 0.16);
	// Clouds: soft white drifts.
	float n = 0.65 * noise(at / 260.0) + 0.35 * noise(at / 110.0);
	c = mix(c, vec3(1.0), clouds * 0.45 * smoothstep(0.55, 0.85, n));
	// Paper: soft blotches and darker edges (no per-pixel grain: it would not compress).
	c *= 1.0 - grain * (0.025 * noise(at / 140.0) + 0.07 * smoothstep(0.55, 1.15, distance(UV, vec2(0.5)) * 1.6));
	COLOR = vec4(c, 1.0);
}
"""

## Pages the last render() would make (a preview renders only the first).
var page_count := 0
## Set as the picture leaves the tree: a render still waiting ends with no pages.
var _leaving := false
var _waiting: _Wait
var _look: Dictionary
var _o: Dictionary
var _width := 1280
var _side := 76
var _text := TEXT_SIZE
var _name := NAME_SIZE
var _portrait_side := PORTRAIT
var _words := 820
var _viewport: SubViewport
var _backdrop: ColorRect
var _content: VBoxContainer
var _page_note: Label
var _player := "Anon"


## The kept choices, every missing or unknown one at its default.
static func load_options() -> Dictionary:
	var options := DEFAULTS.duplicate()
	var file := ConfigFile.new()
	if file.load(OPTIONS_PATH) != OK: return options
	for key: String in DEFAULTS:
		var value: Variant = file.get_value("picture", key, DEFAULTS[key])
		if typeof(value) == typeof(DEFAULTS[key]): options[key] = value
	options.look = OLD_LOOKS.get(str(options.look), str(options.look))
	if not LOOKS.has(str(options.look)): options.look = DEFAULTS.look
	if not WIDTHS.has(str(options.width)): options.width = DEFAULTS.width
	if not TEXT_SCALES.has(str(options.text)): options.text = DEFAULTS.text
	if str(options.layout) not in ["bubbles", "script"]: options.layout = DEFAULTS.layout
	return options


static func save_options(options: Dictionary) -> void:
	var file := ConfigFile.new()
	for key: String in DEFAULTS: file.set_value("picture", key, options.get(key, DEFAULTS[key]))
	file.save(OPTIONS_PATH)


## spec: {entries (oldest first), scenes: [{day, start, end, place, entries}] they come from, world,
## tint: Color, player, options (DEFAULTS), preview: only the first page}. Returns the pages.
func render(spec: Dictionary) -> Array[Image]:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_o = DEFAULTS.duplicate(); _o.merge(spec.get("options", {}), true)
	_look = LOOKS.get(str(_o.look), LOOKS.twilight)
	_width = int(WIDTHS.get(str(_o.width), 1280))
	_side = roundi(_width * 0.06)
	var scale := float(TEXT_SCALES.get(str(_o.text), 1.0))
	_text = roundi(TEXT_SIZE * scale); _name = roundi(NAME_SIZE * scale); _portrait_side = roundi(PORTRAIT * scale)
	_words = int((_width - 2 * _side - (_portrait_side + 16 if _o.portraits else 0)) * 0.78)
	_viewport = SubViewport.new(); _viewport.disable_3d = true; _viewport.transparent_bg = false
	_viewport.size = Vector2i(_width, 400); _viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_viewport.gui_disable_input = true
	add_child(_viewport)
	_backdrop = ColorRect.new(); _backdrop.size = Vector2(_viewport.size)
	var material := ShaderMaterial.new(); material.shader = Shader.new(); material.shader.code = BACKDROP
	material.set_shader_parameter("top_color", _look.top); material.set_shader_parameter("bottom_color", _look.bottom)
	for key: String in ["glow_a", "glow_b"]: material.set_shader_parameter(key, _look.get(key, Color(0, 0, 0, 0)))
	for key: String in ["stars", "confetti", "clouds", "grain", "diamonds", "gingham", "rainbow", "bokeh", "sun", "moon", "spotlight", "zebra", "mudcloth"]:
		material.set_shader_parameter(key, float(_look.get(key, 0.0)))
	material.set_shader_parameter("motif", _look.get("motif", Color.WHITE))
	material.set_shader_parameter("star_color", _look.get("star", Color.WHITE))
	material.set_shader_parameter("star_size", float(_look.get("star_size", 1.5)))
	_backdrop.material = material; _viewport.add_child(_backdrop)
	_content = VBoxContainer.new(); _content.position = Vector2(_side, TOP)
	_content.custom_minimum_size.x = _width - _side * 2; _content.add_theme_constant_override("separation", roundi(14 * scale))
	_viewport.add_child(_content)
	_build(spec)
	_page_note = _label("", STYLE.REGULAR, 17, _look.faint); _viewport.add_child(_page_note)
	for i in 3:
		if not await _wait(get_tree().process_frame): return [] as Array[Image]
	var pages := _pages()
	page_count = pages.size()
	if bool(spec.get("preview", false)): pages = pages.slice(0, 1)
	var images: Array[Image] = []
	for i in pages.size():
		var start: float = pages[i][0]
		var height := int(ceilf(float(pages[i][1]) - start)) + (TOP if i == 0 else 40) + BOTTOM
		_viewport.size = Vector2i(_width, height)
		_backdrop.size = Vector2(_viewport.size)
		material.set_shader_parameter("size_px", Vector2(_viewport.size)); material.set_shader_parameter("offset_px", Vector2(0, start))
		_content.position.y = (TOP if i == 0 else 40) - start
		# Rows of the pages before and after stay out of this one's margins.
		for row: Control in _content.get_children():
			# (Pages are cut between rows, so a row is either inside this page or wholly outside it; a
			# first label can sit a pixel above zero.)
			row.modulate.a = 1.0 if row.position.y + row.size.y > start + 0.5 and row.position.y < float(pages[i][1]) - 0.5 else 0.0
		_page_note.visible = page_count > 1
		_page_note.text = "%d / %d" % [i + 1, page_count]
		_page_note.position = Vector2(_width - _side - 60, height - 34); _page_note.size.x = 60
		_page_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		for wait in 2:
			if not await _wait(RenderingServer.frame_post_draw): return [] as Array[Image]
		images.append(_viewport.get_texture().get_image())
	return images


## One wait of render(), which also ends when the picture leaves the tree (the journal closing, the
## game quitting): a render left waiting on a frame that never comes keeps its material alive past
## exit. Not world/shutdown_waits.gd: that stays shut on the title after a game, where the journal
## lives. False when the picture is leaving.
class _Wait extends RefCounted:
	signal done
	func finish() -> void: done.emit()

func _wait(event: Signal) -> bool:
	if _leaving or not is_inside_tree(): return false
	_waiting = _Wait.new()
	var wait := _waiting
	event.connect(wait.finish, CONNECT_ONE_SHOT)
	if not tree_exiting.is_connected(_leave): tree_exiting.connect(_leave, CONNECT_ONE_SHOT)
	await wait.done
	if event.is_connected(wait.finish): event.disconnect(wait.finish)
	_waiting = null
	return not _leaving


func _leave() -> void:
	_leaving = true
	if _waiting != null: _waiting.finish()


## [top, bottom] of each page in content pixels, cut between rows. Pages share the height evenly
## (a long talk gives three even pages, not two full ones and a scrap).
func _pages() -> Array:
	var rows := _content.get_children().filter(func(child: Control) -> bool: return child.visible)
	if rows.is_empty(): return [[0.0, 0.0]]
	var total: float = rows[-1].position.y + rows[-1].size.y
	var count := ceilf(total / PAGE_HEIGHT)
	var target := total / count
	var pages: Array = []
	var start := 0.0
	var end := 0.0
	for child: Control in rows:
		var bottom := child.position.y + child.size.y
		# The last page takes the rest, unless it would outgrow a page.
		var limit: float = float(PAGE_HEIGHT) if pages.size() >= count - 1 else target
		if end > start and bottom - start > limit:
			# This row ends the page when that comes nearer the even height, else the page ends before it.
			if limit < PAGE_HEIGHT and bottom - start <= PAGE_HEIGHT and bottom - start - target < target - (end - start):
				pages.append([start, bottom]); start = bottom; end = bottom; continue
			pages.append([start, end]); start = child.position.y
		end = bottom
	if end > start: pages.append([start, end])
	return pages


# ------------------------------------------------------------------ the picture
func _build(spec: Dictionary) -> void:
	var entries: Array = spec.get("entries", [])
	if not _o.moments: entries = entries.filter(func(e: Dictionary) -> bool: return e.kind != "moment")
	var scenes: Array = spec.get("scenes", [])
	_player = str(spec.get("player", "Anon"))
	_header(spec, entries, scenes)
	var last_speaker := ""
	var scene_index := -1
	var scene_of := {}
	for i in scenes.size():
		for entry: Dictionary in scenes[i].entries: scene_of[int(entry.id)] = i
	for entry: Dictionary in entries:
		var scene := int(scene_of.get(int(entry.id), maxi(0, scenes.size() - 1)))
		if scene != scene_index:
			if _o.headings and scenes.size() > 1: _scene_heading(DATA.scene_line(scenes[scene]).to_upper())
			last_speaker = ""
		scene_index = scene
		if entry.kind == "moment":
			_moment(str(entry.text)); last_speaker = ""; continue
		var speaker := str(entry.speaker)
		_line(entry, speaker != last_speaker)
		last_speaker = speaker
	_footer(spec)


## The logo, the title (the world's name unless one was typed), when and where, and who was there;
## each can be left out.
func _header(spec: Dictionary, entries: Array, scenes: Array) -> void:
	var shown := false
	if _o.logo:
		var logo := TextureRect.new(); logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED; logo.custom_minimum_size.y = 120
		var image := LOGO.get_image()
		if image != null:
			if image.is_compressed(): image.decompress()
			var fit := 120.0 / image.get_height()
			image.resize(int(image.get_width() * fit), 120, Image.INTERPOLATE_LANCZOS)
			logo.texture = ImageTexture.create_from_image(image)
		_content.add_child(logo); shown = true
	var title := str(_o.title).strip_edges()
	if title == "" and _o.world: title = str(spec.get("world", ""))
	if title != "":
		var heading := _label(title, STYLE.HEADING, 46, _look.me)
		# Words that could be long wrap inside the picture's width instead of widening it.
		heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; heading.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_content.add_child(heading); shown = true
	if _o.when:
		var when := _label(_when(entries, scenes), STYLE.BOLD, 21, _look.muted)
		when.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; when.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_content.add_child(when); shown = true
	var cast: Array[String] = []
	for entry: Dictionary in entries:
		for who: String in [str(entry.speaker), str(entry.listener)]:
			if who != DATA.PLAYER and who not in DATA.NOBODY and who not in cast and (entry.kind == "say" or who == str(entry.speaker)): cast.append(who)
	if _o.cast and not cast.is_empty():
		var row := HFlowContainer.new(); row.alignment = FlowContainer.ALIGNMENT_CENTER
		row.add_theme_constant_override("h_separation", 22); row.add_theme_constant_override("v_separation", 10)
		for who in cast.slice(0, CAST_SHOWN):
			var one := VBoxContainer.new(); one.add_theme_constant_override("separation", 4)
			var disc := _portrait(who, 58); disc.size_flags_horizontal = Control.SIZE_SHRINK_CENTER; one.add_child(disc)
			var called := _label(DATA.name_of(who, _player), STYLE.BOLD, 16, _look.muted)
			called.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; called.custom_minimum_size.x = 96
			called.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; one.add_child(called)
			row.add_child(one)
		if cast.size() > CAST_SHOWN:
			var more := _label("+%d" % (cast.size() - CAST_SHOWN), STYLE.BOLD, 22, _look.faint)
			more.custom_minimum_size.y = 58; more.vertical_alignment = VERTICAL_ALIGNMENT_CENTER; row.add_child(more)
		_content.add_child(_gap(4)); _content.add_child(row); shown = true
	if shown: _content.add_child(_ornament())


## "Day 2 · 14:05–14:40 · Ponyville", or the span of days and how many scenes.
func _when(entries: Array, scenes: Array) -> String:
	if entries.is_empty(): return ""
	if scenes.size() <= 1:
		var only: Dictionary = scenes[0] if not scenes.is_empty() else {"day": entries[0].day, "start": entries[0].minute, "end": entries[-1].end_minute, "place": entries[0].place}
		return DATA.scene_line(only)
	var first := int(entries[0].day) + 1
	var last := int(entries[-1].day) + 1
	return ("Day %d" % first if first == last else "Days %d–%d" % [first, last]) + " · %d scenes" % scenes.size()


func _scene_heading(text: String) -> void:
	var row := HBoxContainer.new(); row.add_theme_constant_override("separation", 16)
	_content.add_child(_gap(10))
	row.add_child(_rule(true))
	var words := _label(text, STYLE.BOLD, 16, _look.faint); row.add_child(words)
	row.add_child(_rule(true))
	_content.add_child(row)


## A sparkle between two fading lines.
func _ornament() -> Control:
	var row := HBoxContainer.new(); row.add_theme_constant_override("separation", 14)
	row.custom_minimum_size.y = 34
	row.add_child(_rule(true))
	var mark := ICON.make(str(_look.icon), 22, Color(_look.moment, 0.9)); mark.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(mark)
	row.add_child(_rule(true))
	return row


func _rule(expand: bool) -> Control:
	var line := ColorRect.new(); line.color = _look.rule; line.custom_minimum_size = Vector2(0, 1.5)
	line.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if expand: line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return line


## One reply. Bubbles: her disc and name over the first of a run, the words in a bubble rimmed in
## her colour, the player's on the right. Script: everyone on the left, the words under the name
## beside a thin bar in the speaker's colour.
func _line(entry: Dictionary, first: bool) -> void:
	var speaker := str(entry.speaker)
	var script := str(_o.layout) == "script"
	var mine := speaker == DATA.PLAYER and not script
	var colour := _name_colour(speaker)
	var row := HBoxContainer.new(); row.add_theme_constant_override("separation", 16)
	if first and _content.get_child_count() > 0: _content.add_child(_gap(6))
	var side: Control = null
	if _o.portraits:
		side = _portrait(speaker, _portrait_side) if first else Control.new()
		side.custom_minimum_size = Vector2.ONE * _portrait_side; side.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	var column := VBoxContainer.new(); column.add_theme_constant_override("separation", 6)
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if first:
		var head := HBoxContainer.new(); head.add_theme_constant_override("separation", 12)
		head.alignment = BoxContainer.ALIGNMENT_END if mine else BoxContainer.ALIGNMENT_BEGIN
		var called := _label(DATA.name_of(speaker, _player), STYLE.HEADING, _name, colour)
		var to := DATA.name_of(str(entry.listener), _player) if _o.addressee and (str(entry.listener) != DATA.PLAYER or speaker == DATA.PLAYER) else ""
		var aside := ("to " + to if to != "" else "") + ("  ·  " if to != "" and _o.times else "") + (DATA.clock(int(entry.minute)) if _o.times else "")
		var note := _label(aside, STYLE.REGULAR, roundi(_text * 0.68), _look.faint); note.size_flags_vertical = Control.SIZE_SHRINK_END
		if mine: head.add_child(note); head.add_child(called)
		else: head.add_child(called); head.add_child(note)
		column.add_child(head)
	var words := _label(str(entry.text), STYLE.REGULAR, _text, _look.text)
	words.add_theme_constant_override("line_spacing", roundi(_text * 0.2))
	if script:
		var said := HBoxContainer.new(); said.add_theme_constant_override("separation", 14)
		var bar := ColorRect.new(); bar.color = Color(colour, 0.55); bar.custom_minimum_size.x = 3
		said.add_child(bar)
		words.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; words.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		said.add_child(words)
		column.add_child(said)
	else:
		var bubble := PanelContainer.new()
		var rim: Color = _look.mine_rim if mine else Color(colour if _look.dark else _ink(colour, 0.2), _look.rim)
		var style := STYLE.box(_look.mine if mine else _look.bubble, rim, 2 if rim.a > 0.0 else 0, roundi(22 * _text / float(TEXT_SIZE)), roundi(_text * 0.88), roundi(_text * 0.52))
		# The corner by the speaker is tighter, like a speech bubble's tail.
		if first:
			if mine: style.corner_radius_top_right = 6
			else: style.corner_radius_top_left = 6
		bubble.add_theme_stylebox_override("panel", STYLE.rounded(style))
		bubble.size_flags_horizontal = Control.SIZE_SHRINK_END if mine else Control.SIZE_SHRINK_BEGIN
		if STYLE.REGULAR.get_string_size(words.text, HORIZONTAL_ALIGNMENT_LEFT, -1, _text).x > _words:
			words.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; words.custom_minimum_size.x = _words
		bubble.add_child(words)
		column.add_child(bubble)
	if mine:
		row.add_child(column)
		if side != null: row.add_child(side)
	else:
		if side != null: row.add_child(side)
		row.add_child(column)
	_content.add_child(row)


func _moment(text: String) -> void:
	var row := HBoxContainer.new(); row.alignment = BoxContainer.ALIGNMENT_CENTER; row.add_theme_constant_override("separation", 12)
	_content.add_child(_gap(6))
	var size := roundi(_text * 0.88)
	var widest := int((_width - 2 * _side) * 0.78)
	for i in 2:
		var mark := ICON.make(str(_look.icon), 20, _look.moment); mark.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		if i == 1:
			var words := _label(text, STYLE.ITALIC, size, _look.moment if _look.dark else _look.muted)
			words.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			if STYLE.ITALIC.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x > widest:
				words.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; words.custom_minimum_size.x = widest
			row.add_child(words)
		row.add_child(mark)
	_content.add_child(row)


func _footer(spec: Dictionary) -> void:
	if not _o.footer: return
	_content.add_child(_gap(12))
	_content.add_child(_ornament())
	var row := HBoxContainer.new(); row.alignment = BoxContainer.ALIGNMENT_CENTER; row.add_theme_constant_override("separation", 12)
	row.add_child(_label("Home: Equestria", STYLE.HEADING, 24, _look.muted))
	var bits: Array[String] = []
	if _o.world and str(spec.get("world", "")) != "": bits.append(str(spec.world))
	if _o.date:
		var date := Time.get_date_dict_from_system()
		var months := ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
		bits.append("%s %d, %d" % [months[int(date.month) - 1], int(date.day), int(date.year)])
	if not bits.is_empty():
		var line := _label("·  " + "  ·  ".join(bits), STYLE.REGULAR, 17, _look.faint); line.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		line.clip_text = true; line.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		line.custom_minimum_size.x = minf(STYLE.REGULAR.get_string_size(line.text, HORIZONTAL_ALIGNMENT_LEFT, -1, 17).x, _width - _side * 2 - 260)
		row.add_child(line)
	_content.add_child(row)


# ------------------------------------------------------------------ parts
func _label(text: String, font: Font, size: int, colour: Color) -> Label:
	var node := Label.new(); node.text = text
	node.add_theme_font_override("font", font); node.add_theme_font_size_override("font_size", size)
	node.add_theme_color_override("font_color", colour)
	return node


func _gap(height: float) -> Control:
	var gap := Control.new(); gap.custom_minimum_size.y = height
	return gap


## Her name's colour: her coat, lifted to read on a dark look (as over her head) or deepened on a light one.
func _name_colour(id: String) -> Color:
	if id == DATA.PLAYER: return _look.me
	var coat: Color = PONY_DATA.appearance(id).coat
	return OVERHEAD._readable(coat) if _look.dark else _ink(coat, 0.16)


## The colour darkened until it reads on a light look (relative luminance at most `most`).
func _ink(colour: Color, most: float) -> Color:
	var result := Color(colour, 1.0)
	for i in 12:
		var linear := result.srgb_to_linear()
		if 0.2126 * linear.r + 0.7152 * linear.g + 0.0722 * linear.b <= most: break
		result = result.darkened(0.15)
	return result


## Her cutie mark on her coat in a ring; the player gets a disc with their initial.
func _portrait(id: String, side: float) -> Control:
	var disc := Panel.new(); disc.custom_minimum_size = Vector2(side, side); disc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if id == DATA.PLAYER:
		var fill: Color = _look.mine_rim if _look.mine_rim.a > 0.5 else _look.mine
		disc.add_theme_stylebox_override("panel", STYLE.rounded(STYLE.box(Color(fill.darkened(0.25), 1.0), fill.lightened(0.2), 2, 99, 0, 0)))
		var letter := _label(_player.left(1).to_upper(), STYLE.HEADING, int(side * 0.52), STYLE.CREAM)
		letter.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; letter.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		letter.size = Vector2(side, side); disc.add_child(letter)
		return disc
	var look := PONY_DATA.appearance(id)
	var ring := Color(1, 1, 1, 0.85) if _look.dark else _ink(look.coat, 0.2)
	disc.add_theme_stylebox_override("panel", STYLE.rounded(STYLE.box(look.coat, ring, 2, 99, 0, 0)))
	PONY_DATA.load_icons()
	var icon: Dictionary = PONY_DATA.icons.get(id, {})
	# The princesses' marks are blank in the atlas: their sun / moon instead of an empty disc.
	if icon.is_empty() or PONY_DATA.atlas == null or bool(icon.get("blank", false)):
		preload("res://world/ui/pony_symbol.gd").add_to(disc, id, side)
		return disc
	var mark := TextureRect.new(); mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var region := AtlasTexture.new(); region.atlas = PONY_DATA.atlas
	var rect: Array = icon.rect
	region.region = Rect2(rect[0], rect[1], rect[2], rect[3])
	mark.texture = region; mark.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	mark.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	mark.size = Vector2.ONE * side * 0.66; mark.position = Vector2.ONE * side * 0.17
	disc.add_child(mark)
	return disc


# ------------------------------------------------------------------ saving
## Where pictures go: Pictures/Home Equestria on desktop, else the game's own folder.
static func folder() -> String:
	var pictures := OS.get_system_dir(OS.SYSTEM_DIR_PICTURES)
	if pictures == "" or OS.has_feature("android"): return ProjectSettings.globalize_path("user://pictures")
	return pictures.path_join("Home Equestria")


## Saves the pages as PNGs named after the world and the moment; returns their paths, or [] on failure.
static func save(images: Array[Image], world: String, when: String) -> Array[String]:
	var where := folder()
	DirAccess.make_dir_recursive_absolute(where)
	var base := ("Home Equestria - %s - %s" % [world, when]).validate_filename()
	var stem := base
	var n := 2
	while FileAccess.file_exists(where.path_join(stem + ".png")) or FileAccess.file_exists(where.path_join(stem + " (1).png")):
		stem = "%s (%d)" % [base, n]; n += 1
	var paths: Array[String] = []
	for i in images.size():
		var path := where.path_join(stem + (" (%d)" % (i + 1) if images.size() > 1 else "") + ".png")
		if images[i].save_png(path) != OK: return []
		paths.append(path)
	return paths
