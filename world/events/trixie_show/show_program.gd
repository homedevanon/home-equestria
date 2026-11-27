extends Node
## What Trixie performs at one show: an opening speech, curtain-up, 4-5 acts drawn from ACT_POOL
## (unseen acts favoured, never guaranteed) with a bow and an announcement between them, and one
## finale; about five minutes (dev 2026-10-28: "it was over way too fast!"). Each act moves simple props only (cards, doves,
## hat, rings, box, cannon) with tweens and per-frame maths; Trixie lights her horn, turns and
## is teleported in puffs, never animated. About one show in five, one part goes wrong (Trixie
## canon). Built by show_runtime.gd, freed after the show.

const FX := preload("res://world/events/trixie_show/show_fx.gd")
const AURA := preload("res://world/characters/magic/magic_aura.gd")
const SHUTDOWN := preload("res://world/shutdown_waits.gd")
const SOUNDS := preload("res://world/audio/interaction_sounds.gd")
const CANNON := preload("res://world/events/trixie_show/show_cannon.gd")
const CARD := preload("res://world/events/trixie_show/props/playing_card.glb")
const HAT := preload("res://world/events/trixie_show/props/magician_hat.glb")
const RINGS := preload("res://world/events/trixie_show/props/magician_rings.glb")
const BOX := preload("res://world/events/trixie_show/props/magician_box.glb")
const TABLE := preload("res://world/events/trixie_show/props/side_table.glb")
const DOVE := preload("res://world/events/trixie_show/props/dove.glb")
const OVERHEAD := preload("res://world/ai/overhead_dialogue.gd")

const ACT_POOL := ["cards", "pick_card", "doves", "rings", "vanish", "cannon"]
const FINALES := {"fireworks": 3.0, "confetti": 2.0, "dove_release": 1.0}
const MISHAP_CHANCE := 0.2
const CARD_COUNT := 52
const CARD_SCALE := 1.8
const DOVE_COUNT := 7
## Stage doves read from the back of the crowd; life size they were specks.
const DOVE_SCALE := 1.8
## The doves circle over the crowd this long before they land.
const DOVE_CIRCLE := 22.0
## How each trick is named in her lines, and what a watcher sees of it (her prompt, audience.gd).
const ACT_TEASE := {"cards": "the dancing deck of cards", "pick_card": "a card trick with a volunteer from the audience",
	"doves": "the doves from the magic hat", "rings": "the linking rings", "vanish": "the vanishing box",
	"cannon": "the human cannonball"}
const ACT_MOMENT := {"cards": "Trixie makes a whole deck of cards dance in the air in rings, stars and a heart",
	"pick_card": "Trixie floats a card to a pony in the crowd, then pulls it back out of her hat",
	"doves": "Trixie pulls a flock of doves out of her magician's hat",
	"rings": "Trixie spins and links metal rings in the air around herself",
	"vanish": "Trixie disappears in her magic box and pops up behind the crowd",
	"cannon": "Trixie fires a human cannonball out of her stage cannon"}
## What the crowd calls out (words over their heads, no AI call): a few ponies at each moment.
const SHOUTS := {
	"gasp": ["Ooooh!", "Whoa!", "No way!", "Wow!", "How?!", "Ooh, look!"],
	"smile": ["Bravo!", "Yay, Trixie!", "Encore!", "Amazing!", "Woo-hoo!", "That was awesome!", "Again!"],
	"giggle": ["Pfft!", "Hee hee!", "Oops!", "Ha!", "Nice one, Trixie!"],
}
const PALETTE := [Color(0.35, 0.55, 1.0), Color(0.7, 0.4, 1.0), Color(1.0, 0.5, 0.85), Color(1.0, 0.85, 0.35), Color(0.5, 0.95, 1.0)]

var runtime: Node
var rng := RandomNumberGenerator.new()
var acts: Array[String] = []
var finale := "fireworks"
var mishap := ""                  # act (or "finale") that goes wrong this show, or ""
var performed: Array[String] = []
var finished := false
var _alive := true
var _stage_set: Node3D                  # every prop of the show lives under here
var _table: Node3D
var _hat: Node3D
var _box: Node3D
var _rings: Array[Node3D] = []
var _lights: Array[Light3D] = []
var _cards: MultiMeshInstance3D
var _card_state := {}             # formation, time, per-card transforms/velocities
var _doves: Array[Node3D] = []
var _dove_state := {}
var _reaction_serial := 0
var _reaction_touches: Dictionary = {}

func prepare(rt: Node, seed_value: int, seen: Array) -> void:
	runtime = rt
	rng.seed = seed_value
	var count := rng.randi_range(4, 5)
	var pool: Array = ACT_POOL.duplicate()
	while acts.size() < count and not pool.is_empty():
		var total := 0.0
		for a: String in pool: total += 3.0 if a not in seen else 1.0
		var pick := rng.randf() * total
		for a: String in pool:
			pick -= 3.0 if a not in seen else 1.0
			if pick <= 0.0:
				acts.append(a); pool.erase(a); break
	var finales := FINALES.duplicate()
	if "doves" in acts: finales.erase("dove_release")
	var ftotal := 0.0
	for f: String in finales: ftotal += float(finales[f])
	var fpick := rng.randf() * ftotal
	for f: String in finales:
		fpick -= float(finales[f])
		if fpick <= 0.0: finale = f; break
	if rng.randf() < MISHAP_CHANCE:
		var options: Array = acts.filter(func(a: String) -> bool: return a != "cannon") + ["finale"]
		mishap = options[rng.randi() % options.size()]

func begin() -> void:
	_stage_set = Node3D.new(); _stage_set.name = "TrixieShowSet"
	runtime.game.add_child(_stage_set)
	preload("res://world/events/trixie_show/show_catalogue.gd").register(_stage_set)
	_build_set()
	_run()

func _run() -> void:
	if not await _opening_speech(): return
	await _curtain_up()
	for i in acts.size():
		if not _alive: return
		var act := acts[i]
		_moment(str(ACT_MOMENT.get(act, "a magic trick")))
		var done: bool = await call("_act_" + act)
		if not _alive: return
		if done: performed.append(act)
		var next: String = str(ACT_TEASE.get(acts[i + 1], "another trick")) if i + 1 < acts.size() else "the grand finale"
		if not await _interlude(act if done else "", next): return
	_moment("Trixie's grand finale")
	await call("_finale_" + ("fizzle" if mishap == "finale" else finale))
	if not _alive: return
	performed.append("finale:" + ("fizzle" if mishap == "finale" else finale))
	finished = true

func _wait(seconds: float) -> bool:
	if not _alive: return false
	var ok: bool = await SHUTDOWN.seconds(self, seconds)
	return ok and _alive

## Says her line for this moment and waits until it was spoken (at most `cap` seconds, at least
## `minimum`, so a show nopony hears still keeps its pace). False once the show is gone.
func _speak(key: String, detail := "", cap := 25.0, minimum := 0.0) -> bool:
	var said := [false]
	var queued: bool = runtime.line(key, detail, func() -> void: said[0] = true)
	var waited := 0.0
	while waited < minimum or (queued and not said[0] and waited < cap):
		if not await _wait(0.25): return false
		waited += 0.25
	return true

func _moment(text: String) -> void:
	if runtime.audience != null: runtime.audience.set_moment(text)

## Before the first trick (dev 2026-10-28: "make trixie give a speech on stage before her show
## starts"): she has floated up, the spotlights find her and she addresses the town.
func _opening_speech() -> bool:
	if not await _wait(2.2): return false
	var mark := _mark()
	var front: Vector3 = runtime.stage_front()
	for s: float in [-1.0, 1.0]:
		var from := front + _facing() * 9.0 + _side() * 6.0 * s + Vector3.UP * 7.0
		_lights.append(FX.spotlight(_stage_set, from, mark + Vector3.UP * 1.0))
	_moment("under the spotlights, Trixie gives her opening speech before the show")
	_shout("smile")
	if not await _wait(2.0): return false
	if not await _speak("speech_open", "", 30.0, 7.0): return false
	if not await _wait(1.0): return false
	if not await _speak("speech_promise", str(ACT_TEASE.get(acts[0], "her first trick")) if not acts.is_empty() else "her first trick", 30.0, 7.0): return false
	return await _wait(1.5)

## Between two tricks: applause, a bow and her announcement of the next one.
func _interlude(last: String, next: String) -> bool:
	_shout("smile")
	if not await _wait(3.0): return false
	_moment("Trixie takes a bow between tricks; next she promises %s" % next)
	if not await _speak("interlude", "%s|%s" % [str(ACT_TEASE.get(last, "that trick")), next], 25.0, 9.0): return false
	return await _wait(3.0)

## A few watchers call out (words over their heads, staggered).
func _shout(kind: String) -> void:
	if runtime.audience == null or not SHOUTS.has(kind): return
	var watchers: Array[Node3D] = runtime.audience.watchers()
	var lines: Array = SHOUTS[kind]
	for i in mini(watchers.size(), rng.randi_range(2, 4)):
		var pick := rng.randi_range(i, watchers.size() - 1)
		var pony := watchers[pick]; watchers[pick] = watchers[i]; watchers[i] = pony
		get_tree().create_timer(rng.randf_range(0.1, 1.4)).timeout.connect(_pop_shout.bind(weakref(pony), str(lines[rng.randi() % lines.size()])))

func _pop_shout(ref: WeakRef, text: String) -> void:
	var pony := ref.get_ref() as Node3D
	if not _alive or not is_instance_valid(_stage_set) or not is_instance_valid(pony) or not pony.is_inside_tree(): return
	var coat := Color.WHITE
	var identity: Variant = pony.get("identity")
	if identity is Resource and identity.get("coat_fill") is Color: coat = identity.get("coat_fill")
	var label := Label3D.new()
	label.text = text
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 56
	label.outline_size = 14
	label.pixel_size = 0.0035
	label.modulate = OVERHEAD._readable(coat)
	label.outline_modulate = Color.BLACK
	label.transparency = 1.0
	_stage_set.add_child(label)
	var head: Vector3 = pony.speech_indicator_point() if pony.has_method("speech_indicator_point") else pony.global_position + Vector3.UP * 1.5
	label.global_position = head
	var tween := label.create_tween()
	tween.tween_property(label, "transparency", 0.0, 0.15)
	tween.parallel().tween_property(label, "global_position", head + Vector3.UP * 0.35, 2.8)
	tween.tween_property(label, "transparency", 1.0, 0.5)
	tween.tween_callback(label.queue_free)

# ------------------------------------------------------------------ helpers
func _trixie() -> Node3D: return runtime.trixie()
func _facing() -> Vector3: return runtime.facing()
func _side() -> Vector3: return runtime.facing().cross(Vector3.UP)
func _mark() -> Vector3: return runtime.stage_mark()
func _colour() -> Color:
	var t := _trixie()
	return preload("res://world/characters/magic/unicorn_magic.gd").color_for(t.identity) if t != null and t.get("identity") != null else Color(0.4, 0.6, 1.0)

## A point on the stage's front edge, `across` metres to the side, on the boards.
func _edge(across: float) -> Vector3:
	var p: Vector3 = runtime.stage_front() - _facing() * 0.4 + _side() * across
	p.y = runtime.deck_height(p) + 0.05
	return p

func _horn(seconds: float) -> void:
	var t := _trixie()
	if t != null and t.has_method("cast_magic"): t.cast_magic(seconds)

func _line(key: String, detail := "") -> void:
	if runtime.has_method("line"): runtime.line(key, detail)

## Audience faces: "smile" (a happy touch for a while), "gasp" (a surprised look), "giggle".
func _react(kind: String, seconds := 4.0) -> void:
	if runtime.audience == null: return
	_shout(kind)
	if kind == "smile" and not runtime.audience.watchers().is_empty():
		SOUNDS.play_at(_stage_set, "show_applause", runtime.stage_front() + _facing() * 8.0)
	for pony: Node3D in runtime.audience.watchers():
		if pony.get("expressions") == null: continue
		match kind:
			"gasp":
				if not pony.has_method("set_dialogue_expression"): continue
				pony.set_dialogue_expression("surprised")
				# The face owner cancels this expiry when a later spoken face replaces it.
				pony.expressions.finish_dialogue(seconds)
			_:
				_reaction_serial += 1
				var key := "show:%d:%d" % [get_instance_id(), _reaction_serial]
				_reaction_touches[key] = weakref(pony)
				pony.expressions.touch(key, 0.9 if kind == "smile" else 1.0, 0.25 if kind == "giggle" else 0.0)
				get_tree().create_timer(seconds).timeout.connect(_release_reaction.bind(key))

func _release_reaction(key: String) -> void:
	var reference: WeakRef = _reaction_touches.get(key)
	_reaction_touches.erase(key)
	var pony: Node = reference.get_ref() if reference != null else null
	if is_instance_valid(pony) and pony.get("expressions") != null:
		pony.expressions.release_touch(key)

func _place(packed: PackedScene, at: Vector3, yaw_toward := Vector3.INF) -> Node3D:
	var node := packed.instantiate() as Node3D
	_stage_set.add_child(node)
	node.global_position = at
	if yaw_toward.is_finite():
		var d := yaw_toward - at; d.y = 0.0
		if d.length() > 0.01: node.global_basis = Basis.looking_at(d.normalized(), Vector3.UP)
	return node

func _poof(at: Vector3, size := 1.0) -> void:
	FX.puff(_stage_set, at, _colour().lightened(0.5), size)
	preload("res://world/characters/magic/unicorn_magic.gd").burst(_stage_set, at - _stage_set.global_position, _colour(), 0.9, 0.35 * size)

func _build_set() -> void:
	var mark := _mark()
	var audience_dir := mark + _facing() * 10.0
	_table = _place(TABLE, mark + _side() * 1.6 + _facing() * 0.3, audience_dir)
	_hat = _place(HAT, _table.global_position + Vector3.UP * 0.71, audience_dir)
	_hat.visible = "doves" in acts or "pick_card" in acts or finale == "dove_release"
	_box = _place(BOX, mark - _side() * 2.4 - _facing() * 0.6, audience_dir)
	_box.visible = "vanish" in acts
	var rings: Node3D = null
	if "rings" in acts:
		rings = RINGS.instantiate() as Node3D
		_stage_set.add_child(rings)
		rings.global_position = _table.global_position + Vector3.UP * 0.72 - _side() * 0.12
		for child: Node in rings.get_children():
			if child is Node3D: _rings.append(child as Node3D)
	# Nothing pops in (dev 2026-10-17): she floats each prop out from behind the curtain.
	_float_in(_table, 0.0)
	if _box.visible: _float_in(_box, 0.5)
	if _hat.visible: _float_in(_hat, 1.4)
	if rings != null: _float_in(rings, 1.7)

## Where props come from and go back to: behind the stage's backdrop curtain.
func _backstage() -> Vector3:
	var p: Vector3 = runtime.stage_front() - _facing() * 5.0
	p.y = runtime.deck_height(p) + 1.0
	return p

## In her magic from behind the curtain to where it was placed, instead of popping in.
func _float_in(node: Node3D, delay := 0.0, seconds := 1.4, from := Vector3.INF) -> void:
	if not is_instance_valid(node): return
	node.set_meta("show_prop", true)
	var goal := node.global_position
	node.global_position = from if from.is_finite() else _backstage()
	var tween := node.create_tween()
	if delay > 0.0: tween.tween_interval(delay)
	var aura: Array = [null]
	tween.tween_callback(func() -> void: aura[0] = AURA.create(node, _colour(), 0.8, -1.0, true))
	tween.tween_property(node, "global_position", goal, seconds).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.tween_callback(func() -> void: if is_instance_valid(aura[0]): (aura[0] as Node).call("release"))

## Back behind the curtain in her magic, then gone (no puff, no pop).
func _float_out(node: Node3D, delay := 0.0) -> void:
	if not is_instance_valid(node): return
	var tween := node.create_tween()
	if delay > 0.0: tween.tween_interval(delay)
	var aura: Array = [null]
	tween.tween_callback(func() -> void: aura[0] = AURA.create(node, _colour(), 0.8, -1.0, true))
	tween.tween_property(node, "global_position", _backstage(), 1.4).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.tween_callback(node.queue_free)

# ------------------------------------------------------------------ curtain up
func _curtain_up() -> void:
	var mark := _mark()
	for s: float in [-1.0, 1.0]:
		FX.sparks(_stage_set, _edge(2.6 * s), 2.5)
	_poof(mark + Vector3.UP * 0.8, 1.6)
	SOUNDS.play_at(_stage_set, "show_boom", mark)
	_horn(3.0)
	_react("gasp", 2.0)
	await _wait(4.0)

# ------------------------------------------------------------------ cards
var _cards_gen := 0
func _cards_build() -> void:
	_cards_gen += 1
	if is_instance_valid(_cards) and not _card_state.is_empty(): return
	if is_instance_valid(_cards): _cards.queue_free()
	var card_mesh: Mesh = null
	var probe := CARD.instantiate()
	for m: Node in probe.find_children("*", "MeshInstance3D", true, false):
		card_mesh = (m as MeshInstance3D).mesh; break
	probe.free()
	_cards = MultiMeshInstance3D.new(); _cards.name = "Cards"
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = card_mesh
	mm.instance_count = CARD_COUNT
	_cards.multimesh = mm
	_cards.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Moved every frame from _process; physics interpolation would fight that.
	_cards.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_stage_set.add_child(_cards)
	_cards.global_transform = Transform3D.IDENTITY
	var deck := _table.global_position + Vector3.UP * 0.74 + _side() * 0.12
	var xs: Array[Transform3D] = []
	var vs: Array[Vector3] = []
	for i in CARD_COUNT:
		xs.append(Transform3D(Basis.from_euler(Vector3(PI * 0.5, 0, 0)).scaled(Vector3.ONE * CARD_SCALE), deck + Vector3.UP * 0.002 * i))
		vs.append(Vector3.ZERO)
	_card_state = {"formation": "deck", "t": 0.0, "xs": xs, "vs": vs, "deck": deck, "landed": []}
	set_process(true)

func _formation_target(i: int, t: float) -> Transform3D:
	var f: String = _card_state.formation
	var centre := _mark() + Vector3.UP * 2.6
	var right := _side(); var up := Vector3.UP
	var face := Basis.looking_at(_facing(), Vector3.UP)   # the starry card back toward the audience
	var s := float(i) / CARD_COUNT
	var p := Vector2.ZERO
	match f:
		"deck", "shuffle":
			var deck: Vector3 = _card_state.deck
			if f == "shuffle":
				var a := s * TAU + t * 4.0
				return Transform3D(face.scaled(Vector3.ONE * CARD_SCALE), deck + Vector3.UP * (0.6 + 0.15 * sin(a * 3.0)) + right * cos(a) * 0.35 + _facing() * sin(a) * 0.35)
			return Transform3D(Basis.from_euler(Vector3(PI * 0.5, 0, 0)).scaled(Vector3.ONE * CARD_SCALE), deck + Vector3.UP * 0.002 * i)
		"ring":
			var a := s * TAU + t * 1.2
			p = Vector2(cos(a), sin(a)) * 1.7
			return Transform3D((face * Basis(Vector3.BACK, a + PI * 0.5)).scaled(Vector3.ONE * CARD_SCALE), centre + right * p.x + up * p.y)
		"star":
			var corners: Array[Vector2] = []
			for k in 10:
				var r := 1.9 if k % 2 == 0 else 0.8
				var ang := PI * 0.5 + k * TAU / 10.0 + t * 0.3
				corners.append(Vector2(cos(ang), sin(ang)) * r)
			var seg := s * 10.0
			var k0 := int(seg) % 10
			p = corners[k0].lerp(corners[(k0 + 1) % 10], seg - floor(seg))
		"letter":
			if i < 20: p = Vector2(lerpf(-1.3, 1.3, i / 19.0), 1.1)
			else: p = Vector2(0.0, lerpf(1.0, -1.5, (i - 20) / 31.0))
		"heart":
			var a := s * TAU
			p = Vector2(16.0 * pow(sin(a), 3), 13.0 * cos(a) - 5.0 * cos(2 * a) - 2.0 * cos(3 * a) - cos(4 * a)) * 0.11
	return Transform3D(face.scaled(Vector3.ONE * CARD_SCALE), centre + right * p.x + up * p.y)

func _process(delta: float) -> void:
	var busy := false
	if is_instance_valid(_cards) and not _card_state.is_empty():
		busy = true
		_card_state.t = float(_card_state.t) + delta
		var mm := _cards.multimesh
		var xs: Array = _card_state.xs
		var vs: Array = _card_state.vs
		for i in CARD_COUNT:
			var x: Transform3D = xs[i]
			if _card_state.formation == "scatter":
				var v: Vector3 = vs[i]
				if i in _card_state.landed: continue
				v.y -= 2.2 * delta
				v *= 1.0 - minf(0.9 * delta, 0.5)
				# Flutter: paper sways as it falls.
				var sway := sin(float(_card_state.t) * 5.0 + i) * 0.6
				x.origin += (v + _side() * sway * 0.5) * delta
				x.basis = x.basis.rotated(Vector3(sin(i), 1, cos(i)).normalized(), delta * 3.0)
				var ground := _ground(x.origin)
				# Resting on the grass, not sunk into it (the collider sits a little over the height map).
				if x.origin.y <= ground + 0.04:
					x.origin.y = ground + 0.04
					x.basis = Basis.from_euler(Vector3(PI * 0.5, rng.randf() * TAU, 0)).scaled(Vector3.ONE * CARD_SCALE)
					(_card_state.landed as Array).append(i)
				vs[i] = v
			else:
				var goal := _formation_target(i, float(_card_state.t))
				var k := 1.0 - exp(-6.0 * delta)
				x = Transform3D(x.basis.orthonormalized().slerp(goal.basis.orthonormalized(), k).scaled(Vector3.ONE * CARD_SCALE), x.origin.lerp(goal.origin, k))
			xs[i] = x
			mm.set_instance_transform(i, x)
	if not _dove_state.is_empty():
		busy = true
		_doves_step(delta)
	if not busy: set_process(false)

func _ground(p: Vector3) -> float:
	return float(WorldTerrain.instance.height_at(p)) if WorldTerrain.instance != null else p.y - 1.0

func _cards_scatter(over_audience: bool) -> void:
	_card_state.formation = "scatter"
	var vs: Array = _card_state.vs
	for i in CARD_COUNT:
		var out := _facing() * rng.randf_range(2.0, 6.0) if over_audience else _facing() * rng.randf_range(-0.5, 0.5)
		vs[i] = out + _side() * rng.randf_range(-3.0, 3.0) + Vector3.UP * rng.randf_range(1.5, 3.5)
	(_card_state.landed as Array).clear()

## The cards lie where they fell for a while, then go, unless a later act took them up again.
func _cards_clear() -> void:
	if not is_instance_valid(_cards): return
	var cards := _cards
	var gen := _cards_gen
	get_tree().create_timer(6.0).timeout.connect(func() -> void:
		if gen != _cards_gen or not is_instance_valid(cards): return
		# They fly back up into a deck on her table instead of vanishing off the grass.
		_card_state.deck = _table.global_position + Vector3.UP * 0.74 + _side() * 0.12 if is_instance_valid(_table) else _backstage()
		_card_state.formation = "deck"
		(_card_state.landed as Array).clear()
		set_process(true))

func _act_cards() -> bool:
	_cards_build()
	_line("cards")
	_horn(40.0)
	_poof(_card_state.deck, 0.6)
	if not await _wait(3.0): return false
	_card_state.formation = "shuffle"
	if not await _wait(5.0): return false
	for f: String in ["ring", "star", "letter", "heart"]:
		_card_state.formation = f
		if f == "ring": _react("gasp", 2.0)
		if mishap == "cards" and f == "star":
			# Mishap: the formation collapses onto Trixie's head.
			_card_state.deck = _mark() + Vector3.UP * 1.4
			_cards_scatter(false)
			_react("giggle", 5.0)
			_line("mishap", "her cards collapsed and rained down on her own head")
			if not await _wait(6.0): return false
			_cards_clear()
			return true
		if not await _wait(7.0): return false
	_react("smile", 6.0)
	_cards_scatter(true)
	if not await _wait(8.0): return false
	_cards_clear()
	return true

func _act_pick_card() -> bool:
	if runtime.audience == null: return false
	var watchers: Array[Node3D] = runtime.audience.watchers()
	if watchers.is_empty(): return false
	var volunteer: Node3D = watchers[rng.randi() % watchers.size()]
	_cards_build()
	_line("pick_card", preload("res://world/population/pony_population_config.gd").pony_name(str(volunteer.identity.id)))
	_horn(30.0)
	_card_state.formation = "deck"
	if not await _wait(3.0): return false
	# One card floats to the volunteer and hovers before her eyes.
	var card := CARD.instantiate() as Node3D
	_stage_set.add_child(card)
	card.scale = Vector3.ONE * CARD_SCALE
	card.global_position = _card_state.deck + Vector3.UP * 0.2
	var aura: Node3D = AURA.create(card, _colour(), 1.0, 0.3, true)
	var at: Vector3 = volunteer.global_position + Vector3.UP * 1.0 - (volunteer.global_position - _mark()).normalized() * 0.6
	var nav: Node = volunteer.get_node_or_null("Navigator")
	if nav != null: nav.face_point = at
	var t := card.create_tween()
	t.tween_property(card, "global_position", at, 2.0).set_trans(Tween.TRANS_SINE)
	card.look_at_from_position(card.global_position, volunteer.global_position + Vector3.UP, Vector3.UP)
	if not await _wait(8.0): return false
	# Back into the deck, a mid-air shuffle, and the same card comes out of the hat.
	t = card.create_tween()
	t.tween_property(card, "global_position", _card_state.deck, 1.6).set_trans(Tween.TRANS_SINE)
	if not await _wait(1.7): return false
	card.visible = false
	if nav != null: nav.face_point = runtime.stage_front() - _facing() * 2.0
	_card_state.formation = "shuffle"
	if not await _wait(6.0): return false
	_card_state.formation = "deck"
	_hat.visible = true
	_poof(_hat.global_position + Vector3.UP * 0.4, 0.7)
	card.visible = true
	card.global_position = _hat.global_position + Vector3.UP * 0.2
	t = card.create_tween()
	t.tween_property(card, "global_position", _hat.global_position + Vector3.UP * 1.6, 1.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_react("gasp", 2.5)
	if not await _wait(5.0): return false
	_react("smile", 5.0)
	if is_instance_valid(aura): aura.release()
	_poof(card.global_position, 0.5)
	card.queue_free()
	_cards_clear()
	return true

# ------------------------------------------------------------------ doves
func _act_doves() -> bool:
	_line("doves")
	_horn(10.0)
	_hat.visible = true
	var aura: Node3D = AURA.create(_hat, _colour(), 1.0, -1.0, true)
	var tip := _hat.create_tween()
	tip.tween_property(_hat, "rotation:z", 0.5, 0.6).set_trans(Tween.TRANS_BACK)
	if not await _wait(3.5): return false
	var mouth := _hat.global_position + Vector3.UP * 0.45
	if mishap == "doves":
		FX.puff(_stage_set, mouth, Color(0.3, 0.3, 0.32), 1.2)
		_spawn_doves(1, mouth)
		_react("giggle", 5.0)
		_line("mishap", "her hat coughed out black smoke and only one dove")
	else:
		FX.feathers(_stage_set, mouth)
		_spawn_doves(DOVE_COUNT, mouth)
		_react("gasp", 2.5)
	if is_instance_valid(aura): aura.release()
	_hat.create_tween().tween_property(_hat, "rotation:z", 0.0, 0.8)
	if not await _wait(DOVE_CIRCLE + 2.0): return false
	_react("smile", 5.0)
	return true

func _spawn_doves(count: int, from: Vector3) -> void:
	var centre := _mark() + Vector3.UP * 4.5 + _facing() * 2.0
	var perches := _perches(count)
	for i in count:
		var dove := DOVE.instantiate() as Node3D
		_stage_set.add_child(dove)
		dove.scale = Vector3.ONE * DOVE_SCALE
		dove.global_position = from
		_doves.append(dove)
	SOUNDS.play_at(_stage_set, "show_wings", from)
	_dove_state = {"t": 0.0, "centre": centre, "perches": perches, "phase": "circle", "leave": false,
		"phase_off": [], "radius": []}
	for i in count:
		(_dove_state.phase_off as Array).append(float(i) / count * TAU)
		(_dove_state.radius as Array).append(3.0 + rng.randf_range(-0.4, 0.8))
	set_process(true)

## Landing spots above the stage (its roof), found by casting down; empty when there is none:
## the doves then keep circling until they fly off.
func _perches(count: int) -> Array:
	var out: Array = []
	var space := _stage_set.get_world_3d().direct_space_state
	for i in count:
		var p := _mark() - _facing() * 1.5 + _side() * lerpf(-2.4, 2.4, float(i) / maxf(count - 1, 1))
		var ray := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 14.0, p + Vector3.UP * 2.2)
		var hit := space.intersect_ray(ray)
		if hit.is_empty(): return []
		out.append(hit.position as Vector3)
	return out

func _doves_step(delta: float) -> void:
	_dove_state.t = float(_dove_state.t) + delta
	var t: float = _dove_state.t
	var centre: Vector3 = _dove_state.centre
	for i in _doves.size():
		var dove := _doves[i]
		if not is_instance_valid(dove): continue
		var target: Vector3
		var flapping := true
		var off: float = (_dove_state.phase_off as Array)[i]
		var radius: float = (_dove_state.radius as Array)[i]
		if bool(_dove_state.leave):
			target = dove.global_position + (Vector3.UP * 0.6 + (_side() * cos(off) - _facing()) * 1.0).normalized() * 9.0
		elif t < 1.0:
			target = centre + (dove.global_position - centre) * 0.5 + Vector3.UP
		elif t < DOVE_CIRCLE or (_dove_state.perches as Array).is_empty():
			var a := off + t * 0.9
			target = centre + Vector3(cos(a), 0.25 * sin(t * 2.0 + off), sin(a)) * radius
		else:
			target = (_dove_state.perches as Array)[i]
			flapping = dove.global_position.distance_to(target) > 0.15
		var step := target - dove.global_position
		var speed := 5.0 if flapping else 0.0
		if step.length() > 0.02:
			var move := step.normalized() * minf(step.length(), speed * delta) if flapping else step
			dove.global_position += move
			var level := Vector3(step.x, step.y * 0.3, step.z)
			if level.length() > 0.05: dove.global_basis = dove.global_basis.orthonormalized().slerp(Basis.looking_at(level.normalized(), Vector3.UP), 1.0 - exp(-8.0 * delta)).scaled(Vector3.ONE * DOVE_SCALE)
		for wing_name: String in ["wing_l", "wing_r"]:
			var wing := dove.find_child(wing_name, true, false) as Node3D
			if wing == null: continue
			var flap := sin(t * 22.0 + off) * 0.9 if flapping else 0.15
			wing.rotation.z = flap if wing_name == "wing_l" else -flap
		if bool(_dove_state.leave) and dove.global_position.distance_to(centre) > 60.0:
			dove.queue_free()

func _doves_leave() -> void:
	if _dove_state.is_empty(): return
	_dove_state.leave = true
	SOUNDS.play_at(_stage_set, "show_wings", _mark() + Vector3.UP * 4.0)

# ------------------------------------------------------------------ rings
func _act_rings() -> bool:
	if _rings.is_empty(): return false
	_line("rings")
	_horn(30.0)
	var trixie := _trixie()
	var auras: Array = []
	for r: Node3D in _rings: auras.append(AURA.create(r, _colour(), 0.8, -1.0, true))
	var around := (trixie.global_position if trixie != null else _mark()) + Vector3.UP * 1.1
	# Up and around Trixie.
	var tween := create_tween().set_parallel(true)
	for i in _rings.size():
		var a := float(i) / _rings.size() * TAU
		tween.tween_property(_rings[i], "global_position", around + Vector3(cos(a), 0.3 * i - 0.4, sin(a)) * 1.1, 1.5).set_trans(Tween.TRANS_SINE)
		tween.tween_property(_rings[i], "rotation", Vector3(PI * 0.5, a, 0.0), 1.5)
	if not await _wait(1.6): return false
	var spin := 0.0
	while spin < 14.0:
		spin += 0.05
		for i in _rings.size():
			var a := float(i) / _rings.size() * TAU + spin * 1.6
			_rings[i].global_position = around + Vector3(cos(a), 0.3 * i - 0.4 + 0.15 * sin(spin * 3.0 + i), sin(a)) * 1.1
			_rings[i].rotation = Vector3(PI * 0.5, -a, 0.0)
		if not await _wait(0.05): return false
	if mishap == "rings":
		for r: Node3D in _rings:
			var fall := create_tween()
			fall.tween_property(r, "global_position", _mark() + Vector3(rng.randf_range(-1, 1), 0.05, rng.randf_range(-1, 1)), 0.6).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
		_react("giggle", 5.0)
		_line("mishap", "her linking rings tangled and clattered onto the stage")
		if not await _wait(4.0): return false
	else:
		# Linked chain in front of her, then stacked back on the table.
		var chain := create_tween().set_parallel(true)
		for i in _rings.size():
			chain.tween_property(_rings[i], "global_position", _mark() + Vector3.UP * 2.0 + _facing() * 0.8 + _side() * (i - 1.5) * 0.24, 1.2)
			chain.tween_property(_rings[i], "global_basis", Basis.looking_at(-_facing(), Vector3.UP) * Basis(Vector3.UP, PI * 0.5 * (i % 2)), 1.2)
		_react("gasp", 2.0)
		if not await _wait(6.0): return false
		_react("smile", 5.0)
	var home := create_tween().set_parallel(true)
	for i in _rings.size():
		home.tween_property(_rings[i], "global_position", _table.global_position + Vector3.UP * (0.72 + 0.04 * i) - _side() * 0.12, 1.2)
		home.tween_property(_rings[i], "global_basis", Basis.IDENTITY, 1.2)
	for a: Variant in auras:
		if is_instance_valid(a): (a as Node).call("release")
	await _wait(1.3)
	return true

# ------------------------------------------------------------------ vanishing box
func _act_vanish() -> bool:
	var trixie := _trixie()
	if trixie == null: return false
	_line("vanish")
	_horn(8.0)
	var start := _box.global_transform
	var middle := _mark() - _facing() * 0.7
	var t := _box.create_tween()
	t.tween_property(_box, "global_position", middle, 1.4).set_trans(Tween.TRANS_SINE)
	if not await _wait(3.5): return false
	# Into the box: she vanishes in a puff, the box spins.
	_poof(trixie.global_position + Vector3.UP * 0.8, 1.2)
	trixie.visible = false
	t = _box.create_tween()
	t.tween_property(_box, "rotation:y", _box.rotation.y + TAU * 4.0, 6.0).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)
	_react("gasp", 3.0)
	if not await _wait(7.0): return false
	_poof(_box.global_position + Vector3.UP * 1.3, 1.6)
	if mishap == "vanish":
		# She was never gone: the puff clears and she is still standing there, sooty.
		trixie.visible = true
		_react("giggle", 5.0)
		_line("mishap", "her vanishing act failed, and when the smoke cleared she was still standing there")
		if not await _wait(4.0): return false
	else:
		# ...and reappears behind the audience.
		var behind: Vector3 = runtime.stage_front() + _facing() * 17.0
		behind.y = _ground(behind)
		runtime.teleport(trixie, behind)
		trixie.visible = true
		if is_instance_valid(trixie.get_node_or_null("Navigator")): trixie.get_node("Navigator").face_point = _mark()
		_react("smile", 6.0)
		_line("vanish_reveal")
		if not await _wait(9.0): return false
		# Back over the heads of the crowd to the stage in her own magic.
		runtime.levitate(trixie, _mark(), 2.6)
		if not await _wait(2.8): return false
	t = _box.create_tween()
	t.tween_property(_box, "global_transform", start, 1.4).set_trans(Tween.TRANS_SINE)
	await _wait(1.5)
	return true

# ------------------------------------------------------------------ human cannonball
func _act_cannon() -> bool:
	var act := CANNON.new()
	act.name = "Cannonball"
	add_child(act)
	var done: bool = await act.perform(self)
	act.queue_free()
	return done

# ------------------------------------------------------------------ finales
func _finale_fireworks() -> void:
	_line("finale")
	_horn(10.0)
	var behind := _mark() - _facing() * 5.0
	var listener: Node3D = runtime._camera()
	for i in rng.randi_range(16, 24):
		var from := behind + _side() * rng.randf_range(-4.0, 4.0)
		var apex := from + Vector3.UP * rng.randf_range(12.0, 20.0) + _facing() * rng.randf_range(3.0, 8.0) + _side() * rng.randf_range(-6.0, 6.0)
		FX.firework(_stage_set, from, apex, PALETTE[rng.randi() % PALETTE.size()], listener)
		if i == 1: _react("gasp", 3.0)
		if i == 10: _react("gasp", 3.0)
		if not await _wait(rng.randf_range(0.6, 1.6)): return
	SOUNDS.play_at(_stage_set, "show_crackle", _mark() + Vector3.UP * 20.0)
	_react("smile", 8.0)
	_doves_leave()
	await _wait(7.0)

func _finale_confetti() -> void:
	_line("finale")
	_horn(12.0)
	var front: Vector3 = runtime.stage_front()
	for wave in 3:
		for s: float in [-1.0, 1.0]:
			FX.confetti(_stage_set, _edge(2.4 * s), Vector3.UP + _facing() * 0.6 - _side() * 0.3 * s)
			FX.sparks(_stage_set, _edge(3.2 * s), 2.0, PALETTE[rng.randi() % PALETTE.size()])
		SOUNDS.play_at(_stage_set, "show_boom", front)
		_react("gasp" if wave < 2 else "smile", 3.0 if wave < 2 else 8.0)
		if wave < 2 and not await _wait(3.5): return
	_doves_leave()
	await _wait(8.0)

func _finale_dove_release() -> void:
	_line("finale")
	_horn(5.0)
	_hat.visible = true
	FX.feathers(_stage_set, _hat.global_position + Vector3.UP * 0.45)
	_spawn_doves(DOVE_COUNT, _hat.global_position + Vector3.UP * 0.45)
	_react("gasp", 2.5)
	if not await _wait(9.0): return
	_doves_leave()
	_react("smile", 6.0)
	await _wait(7.0)

func _finale_fizzle() -> void:
	_line("mishap", "her grand finale firework fizzled with a tiny pop")
	var from := _mark() - _facing() * 4.0
	var rocket_top := from + Vector3.UP * 4.0
	FX.sparks(_stage_set, from, 1.2)
	if not await _wait(1.4): return
	FX.puff(_stage_set, rocket_top, Color(0.4, 0.4, 0.42), 0.6)
	_react("giggle", 6.0)
	await _wait(5.0)

# ------------------------------------------------------------------ teardown
func teardown(graceful := true) -> void:
	for key: String in _reaction_touches.keys(): _release_reaction(key)
	if not _alive:
		if not graceful: _dispose()
		return
	_alive = false
	var t := _trixie()
	if t != null: t.visible = true
	for child: Node in get_children():
		if child.has_method("cancel"): child.cancel()
	if not graceful or not is_instance_valid(_stage_set):
		_dispose()
		return
	for light: Light3D in _lights: FX.fade_out(light)
	_doves_leave()
	if is_instance_valid(_stage_set):
		# The props float back behind the curtain one by one; the cards fly back with them.
		var delay := 0.0
		for node: Node in _stage_set.get_children():
			if node is Node3D and node.has_meta("show_prop") and (node as Node3D).visible:
				_float_out(node as Node3D, delay)
				delay += 0.35
		if is_instance_valid(_cards) and not _card_state.is_empty():
			_card_state.deck = _backstage()
			_card_state.formation = "deck"
			set_process(true)
		var set_node := _stage_set
		# Doves keep flying off a little after the props vanished; then everything goes,
		# this program included (show_runtime.gd hands it over and forgets it).
		get_tree().create_timer(9.0).timeout.connect(func() -> void:
			if is_instance_valid(set_node): set_node.queue_free()
			queue_free())
		for node: Variant in [_table, _hat, _box]:
			if is_instance_valid(node) and not (node as Node3D).visible: (node as Node).queue_free()
		return
	_card_state = {}

func _dispose() -> void:
	_card_state = {}
	_dove_state = {}
	set_process(false)
	if is_instance_valid(_stage_set): _stage_set.queue_free()
	queue_free()

func _exit_tree() -> void:
	teardown(false)
