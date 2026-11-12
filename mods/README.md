# Home: Equestria mods

A mod is one `.pck` file. Players drop it into their mods folder and restart the game, the way
Minecraft takes a `.jar`. Mods can change anything: add code, extend any game script, merge new
data into the game's JSON files, or replace any game file.

## Installing a mod

Put the `.pck` file in the mods folder, then restart the game. **Settings → Mods → Open mods
folder** opens it for you.

| System | Mods folder |
| --- | --- |
| Windows | `%APPDATA%\home-equestria-public\mods\` |
| Linux | `~/.local/share/home-equestria-public/mods/` |
| Quest | `Android/data/org.homeequestria.game/files/mods/` (USB file transfer; create the `mods` folder if it is missing) |

A `mods` folder beside the game's executable works too, and so does a `.pck` placed directly
beside the executable (the older way).

**Settings → Mods** has two lists, **Bundled with the game** and **Your mods**. Each mod shows its
name, version and author, an On/Off switch, and a grey line saying why it is off or held back when
it is. A mod that only runs an entry script switches on and off at once. A mod that extends game
scripts or merges data switches the next time the game starts. Your mods load in file name order,
after the game's own data and the bundled mods, so a mod named `zz_...` loads after one named
`aa_...` and wins when both change the same thing.

## Bundled mods

Some players' mods ship with the game, unchanged, in a `mods/bundled/` folder beside the game
(on Quest, inside the downloaded game data). Each is on or off by default; switch any of them in
**Settings → Mods**. The switch is kept by the mod's id, so it survives updates of that mod.
Bundled mods load before your own mods, in the order the game lists them.

- **Updates.** A newer version of a bundled mod can arrive with a game update or, for mods whose
  author publishes an update address, from **Settings → Mods → Check for mod updates from their
  authors**. Updates are saved in the user-data folder (`mods/bundled_updates/`), checked against
  their sha256 every time the game starts, and never written into the game folder. A file that no
  longer matches is ignored and the bundled version loads.
- **Your own copy.** If your mods folder holds the same mod (same id) as a bundled one, the
  higher version loads and the other is listed as *superseded*. Equal versions keep the bundled
  copy. Delete your copy once the bundled one is as new.
- **Patch packs.** When a bundled mod needs a small fix for the current game, the game ships a
  separate patch pack next to it instead of editing the author's file. It is listed under its mod
  ("includes devanon's patch ..."), has no switch of its own, loads right after its mod, and
  only while that mod is on and has exactly the version the patch was made for.
- **Developer-only mods.** A few bundled mods (the teleports) load, and show in Settings → Mods,
  only while the developer tools are on (Settings → Updates pressed five times). Switching them
  on takes effect at the next start.

**Mods are programs.** A mod can run code on your computer with the same rights as the game.
Only install mods from people you trust.

## Making a mod

You need:

- the game's source project (this repository), unchanged except for your mod's folder;
- the **source data** for the same game version: the `source-data` zips attached to that GitHub
  release. Git leaves out pony bodies, accessories, terrain, grass and some sounds because they
  are too large. Unzip every part into the project's root folder (they are laid out from the
  root and add files without replacing any). Without them the project opens with missing assets
  and your mod cannot be tested;
- **Godot 4.5 stable** (the exact engine version the game uses), standard build;
- your mod in `res://mods/<id>/`. `<id>` uses lower-case letters, digits and `_` only, and must
  be unique (`dinnerbone`, `more_cakes`, `rarity_hats`).

Open the project in the Godot editor once so it imports everything. Then build the pack:

```
godot --headless --xr-mode off --path <project> --script res://tools/modding/build_mod.gd -- <id>
```

That writes `<id>.pck` straight into your own mods folder (the next game launch runs it) and
prints `MOD_BUILT <path>`. Use `--out <file.pck>` to write it elsewhere. Share that one file.

While working, you can run the source project with the unpacked mod, no build needed:

```
godot --xr-mode off --path <project> -- --mod-src <id>
```

`res://mods/dinnerbone/` is a complete small example: every pony walks and does everything
else upside down.

### Folder layout

```
res://mods/<id>/
    mod.json          required: who and what the mod is
    main.gd           optional entry script (a Node), named in mod.json "entry"
    merge/...         optional JSON merged into game data
    ext/...           optional script extensions, listed in mod.json "extends"
    anything else     your scenes, models, textures, sounds, data
```

Only `res://mods/<id>/` goes into the pack, plus files you place at a game path on purpose to
replace it (see below). Never edit game files in the source tree expecting them to ship: they
do not.

### mod.json

```json
{
	"id": "more_cakes",
	"name": "More Cakes",
	"version": "1.0.0",
	"author": "Anon",
	"description": "Sugarcube Corner bakes three new cakes.",
	"game_version": "0.0.3",
	"entry": "res://mods/more_cakes/main.gd",
	"extends": ["res://mods/more_cakes/ext/pony_locomotion.gd"],
	"depends": {"bakery_core": ">=1.2.0"},
	"update_url": "https://example.com/more_cakes/update.json"
}
```

`id` must equal the folder name. `entry` and `extends` are optional. `game_version` records
which game version you made it for (without it, the version the build tool stamps into the pack
counts). A pack that replaces game files and was made for an older game version starts switched
off after a game update, because an old copy of a game file hides what the update changed; the
player can switch it on again in Settings → Mods, which lists the game files each pack replaces.
Raise `game_version` once your mod is checked against the new game. Mods that replace no game
file are never held back. A mod whose `mod.json` is broken is listed in Settings → Mods with the
reason and does not run.

Optional keys:

- `depends`: other mods this one needs, `{"<mod id>": "<version>"}`. The version may be
  `">=1.2.0"`, `">1.2"`, `"=1.2.0"`, `"<2.0"`, a bare `"1.2.0"` (meaning at least that) or `"*"`
  (any). When a dependency is missing, switched off or older, your mod does not run and Settings
  → Mods says which one it needs. It does not change the load order: a dependency that must load
  first needs a file name that sorts first.
- `patches`: for patch packs only, `{"<mod id>": "<exact version>"}`. The pack loads right after
  that mod, switches with it, and stays off when another version of it is installed.
- `update_url`: for bundled mods, an `https://` address of a small JSON file that answers
  `{"version": "1.2.3", "url": "https://.../my_mod.pck", "sha256": "<64 hex digits>", "size": <bytes>}`.
  The game asks it only when the player presses "Check for mod updates from their authors" in
  Settings → Mods, and installs an update only when the player presses its button; the download
  is checked against `sha256` and loads at the next start. Plain `http://` addresses are ignored.
- `scenario`: this mod changes how a new world starts. See "Scenario mods" below.

Any other key is ignored, so a mod made for a newer game still loads. A key listed here with the
wrong shape (a `scenario` that is not valid, `depends` that is not a map) is an error, and the mod
does not run.

## Ways to change the game

Use the first way that does the job. They are ordered from sturdiest to most fragile across game
updates.

### 1. Entry script and hooks

`entry` is a script that extends `Node`. The game adds it under the `Mods` autoload at start-up,
before the title screen, and it lives until the game quits. From it, everything in the scene
tree is reachable, and `Mods` gives you stable shortcuts:

| Call or signal | What it does |
| --- | --- |
| `Mods.world_starting(game, is_new)` | Signal: a world is starting, under the loading screen, after its save is restored and before the opening story reads it. `is_new` is true for a brand-new world (already stamped when a scenario mod runs, see "Scenario mods"). `game.world_context` is open; the world is not loaded yet. |
| `Mods.world_ready(game)` | Signal: a world finished loading. `game` is `res://world/game.gd` and exposes `player`, `world_context` and the game's other systems. |
| `Mods.world_closed(game)` | Signal: the world is being left. |
| `Mods.player_ready(player)` | Signal: the player's body exists in the world. |
| `Mods.on_node(matcher, callback)` | Calls `callback(node)` for every matching node, those already there and every one that enters the tree later, once ready. `matcher` is a script path (matches that script and anything extending it), `"group:<name>"`, `"class:<Godot class>"`, or a `Callable(node) -> bool`. |
| `Mods.state(id)` | Your mod's section of the current world's save, a `Dictionary`. Change it, then call `Mods.save_changed()`. Empty before a world loads. A removed mod's section is kept and does no harm. |
| `Mods.data_folder(id)` | `user://mods/data/<id>/` for your own files outside any world. |
| `Mods.list()`, `Mods.is_active(id)` | Which mods are loaded, so mods can work together. |
| `Mods.scenario()` | The running scenario (`{id, name, version, mod, start, skip_opening, initial_state, description}`), or `{}` when no scenario mod runs. |
| `Mods.pack_rows()` | Every pack seen this launch, in load order, with its title, author, version, `bundled`, `enabled`, `held`, `superseded_by`, `reason`, `warning`, `caution`, `patches`, `patched_by`, `declared` (the mods its `mod.json` files name, also while it is off) and the game files it replaces. The stable way for a mod manager to read the Mods screen's state. |
| `Mods.game` | The current world's `game` node, or null. A mod switched on mid-game has missed `world_ready`, so read this in `_ready`. |

When a player switches your mod off mid-game, its entry node is freed. Put the undo in
`_exit_tree()`: give back the player, restore what you changed on ponies and other nodes, and
free what you added outside your own node.

```gdscript
extends Node

func _ready() -> void:
	Mods.world_ready.connect(_on_world)
	Mods.on_node("res://world/characters/locomotion/pony_locomotion.gd", _on_pony)

func _on_world(game: Node) -> void:
	var visits := int(Mods.state("hello").get("visits", 0)) + 1
	Mods.state("hello").visits = visits
	Mods.save_changed()
	print("Welcome back to Equestria, visit ", visits)

func _on_pony(pony: Node) -> void:
	print("A pony appeared: ", pony.name)
```

### 2. Merge JSON into game data

A file at `res://mods/<id>/merge/<path>` is merged into the game's `res://<path>` before
anything reads it. Objects merge key by key, lists are appended to, and anything else is
replaced. Several mods merging the same file stack up in load order.

`res://mods/more_cakes/merge/world/food/definitions.json` adds to
`res://world/food/definitions.json`. Useful data files include `world/food/definitions.json`,
`world/ai/context_seeds.json` (lore the ponies' AI knows), `world/ai/schedules/*.json`,
`world/characters/background/roster.json`, `world/life/day/day_tables.json` and
`world/zones.json`. Read a file in the source first to learn
its shape.

### 3. Extend a game script

List a script in `"extends"` that starts with `extends "res://<game script>.gd"`. At start-up
it takes over that path, so every pony, door, shop or menu the game creates from then on uses
your subclass. Override a function and call `super(...)` to keep the game's behaviour:

```gdscript
extends "res://world/characters/locomotion/pony_locomotion.gd"

func _physics_process(delta: float) -> void:
	super(delta)
	# your change after hers
```

Two mods may extend the same script; they chain in load order, as long as both call `super`.
Scripts loaded before mods start (the `Settings` autoload and the XR toolkit) cannot be
extended this way.

How it works, and what it needs from you:

- The first line that says `extends "res://..."` names the script you extend. Write it with the
  full `res://` path in double or single quotes, on its own line.
- Ship the extension as plain `.gd` source (the build tool does). The game compiles your source
  at the game script's own path, over a copy of the game's script, so every later `preload()` of
  that path gets your subclass.
- The exported game keeps its own scripts as compiled tokens (`x.gdc` behind `x.gd.remap`). The
  loader copies those as `N.gdc` behind an `N.gd.remap` and your script extends `N.gd`, which is
  how the game itself reaches its scripts. A game script with a `class_name` works too. Extending
  `.gdc` paths yourself does not: never write `extends "res://....gdc"`.
- If an extension does not compile in the player's game (the game script changed and your
  override no longer fits), the game script stays the game's own, your other extensions are undone,
  and Settings → Mods shows "could not extend <path> in this build". Your mod then does not run.
  The log has the compiler's message.

### 4. Replace a game file

Any file in the pack at a game path, such as `res://world/ui/fonts/CelestiaMediumRedux.ttf`,
replaces the game's file. This is the most fragile option: the next game update may change that
file and your copy then breaks or undoes the update. Two mods replacing the same file cannot
both win.

When the game updates, a pack that replaces game files and declares an older `game_version` is
held off until the player switches it on again. When they do, the game first compiles each game
script the pack replaces from the pack's own copy; a copy that no longer compiles keeps the whole
pack off ("its copy of <path> does not work with this game version"). A pack that replaces
`world/game.gd` or `world/game_saves.gd` always carries a warning in Settings → Mods: an old copy
of those breaks new worlds and saves. Prefer extending them.

### AI prompts and personas

Plain text prompt overrides need no pack: **Settings → AI Settings** has a folder for persona
and prompt files, and **Settings → Prompts** edits any prompt in game. A pack can also replace or
merge prompt files like any other data.

## Scenario mods

A scenario mod replaces the start of a new world: a different opening, a different Equestria (a
Nightmare Moon world, say). Its worlds and saves belong to it. Declare it in `mod.json`:

```json
"scenario": {
	"id": "nightmare_moon",
	"name": "Nightmare Moon",
	"start": "res://mods/nightmare_moon/start.gd",
	"skip_opening": true,
	"initial_state": "res://mods/nightmare_moon/initial_state.json",
	"description": "The night never ended."
}
```

| Key | Meaning |
| --- | --- |
| `id` | Required. 1 to 40 lower-case letters, digits or `_`. Saves remember it: never change it once players have worlds. |
| `name` | What menus call it ("Needs the Nightmare Moon mod"). Defaults to the id. |
| `start` | Optional. A `Node` script inside your mod's folder, run when a world of this scenario starts (below). |
| `skip_opening` | Optional, default `false`. `true`: a new world has no forest opening, no tutorial and no Twilight rescue; Anon starts at the normal spawn unless your start node moves him. |
| `initial_state` | Optional. A JSON object inside your mod's folder, deep-merged into the new world's memory (`world_context.state`) once, when the world is created: objects merge key by key, lists append. Use your own key under `"mods": {"<your id>": {...}}` for flags, or game keys you have read the code for (`"lore"`, `"relationships"`, `"arrival"`). `version`, `world_id`, `revision` and `scenario` cannot be set, and a merge that would make the world unreadable is not applied (the log says so). |
| `description` | Optional text for the player. |

A broken `scenario` (bad id, a path outside `res://mods/<id>/`, a missing file) keeps the mod from
running, with the reason in Settings → Mods.

### The start node

```gdscript
extends Node
signal finished

func prepare(game: Node, resumed: bool) -> void:
	# Under the loading screen. resumed: false for a brand-new world, true for a continued one.
	if resumed:
		finished.emit.call_deferred()
		return
	game.arrival.place_player(Vector3(-24.5, 0.0, -259.2), Vector3(0, 0, -1))
	_begin(game)

func _begin(game: Node) -> void:
	var scenario := preload("res://world/modding/scenario.gd")
	if not await scenario.loaded(self): return   # waits until the loading screen is gone
	await game.arrival.place_at_golden_oak(false)
	finished.emit()
```

The game adds it as its child `ScenarioStart` every time a world of your scenario starts, right
after the opening story (`game.arrival`, `res://world/life/arrival_story.gd`) has read the world,
and calls `prepare(game, resumed)`. Emit `finished` once your start is done. With `skip_opening`
the opening has already ended when `prepare` runs; without it, a new world's forest opening waits
until `finished`, so your start plays first and the normal opening follows.

Hooks on `game.arrival` for start nodes (use these instead of copying the opening):

| Call | What it does |
| --- | --- |
| `end_opening(note)` | Ends the opening without playing it (what `skip_opening` does for you). |
| `place_player(at, facing)` | Puts Anon's feet on the ground at `at`, facing `facing`, and streams the world there. In `prepare` the world then loads around that place. |
| `await place_at_golden_oak(via_town)` | Inside Golden Oak Library, facing in. `via_town = true` first stands him in Ponyville and waits for the streaming (needed from far away). Returns false when the world is being left. |
| `await skip_to_free_home()` | The game's own "skip the opening": he wakes in the library, the world remembers that Twilight found him and offered her guest bed, and the opening is done. |
| `await choose_form()` | Asks human Anon or AnonPony, as a new world normally does (the opening asks it; `skip_opening` skips it). |
| `hold_opening(on)` | Holds or releases the forest opening (the game does this around your start node). |

`await preload("res://world/modding/scenario.gd").loaded(node)` waits until the world has loaded.
`Mods.world_starting(game, is_new)` and `Mods.scenario()` are there for entry scripts too.

### Saves and the one-at-a-time rule

- A new world started while your scenario runs is stamped with it: its memory gets
  `"scenario": {"id", "name", "version", "mod"}`, and every save of it carries the id and name in
  its header.
- A save of your scenario loads only while your mod runs. With it off, menus show the save greyed
  out with "Needs the <Name> mod". A save without a scenario (every save made before scenario mods
  existed counts as one) loads only while no scenario mod runs: "Turn off the <Name> mod to load
  this". Continue, Load game, the in-game saved games panel and F8 all follow this. Saves are never
  hidden, moved or changed by it.
- At most one scenario mod runs. Switching one on in Settings → Mods switches the other scenario
  mods off, with a note. If two are switched on (for example after copying packs into the mods
  folder), the first in load order runs and the other is held with the reason.
- Scenario mods switch at the next start of the game, never mid-game.

### Testing a scenario mod

1. Build it (`build_mod.gd -- <id>`), start the game, open Settings → Mods: it shows "Scenario:
   <Name>" and runs.
2. New game: the log prints `[scenario] new world stamped: <id>` and `[scenario] <id> start node`.
   Check your start, then save.
3. Switch the mod off, restart: your save is greyed out with "Needs the <Name> mod"; older saves
   load. Switch it on again: older saves are greyed out with "Turn off the <Name> mod to load this".
4. Continue your scenario world: `prepare(game, true)` runs and the world is as you left it.

The example under `res://mods/example_scenario/` (source repository) skips the forest and starts
Anon in Golden Oak Library with a world flag set. `res://tools/modding/test_scenario_mods.gd` tests
these rules headless.

## UIDs in scenes and resources

Godot gives every scene, resource and script a UID (`uid://...`) and writes it into `.tscn` and
`.tres` files and `.uid` sidecar files. The player's game does not know your mod's UIDs, so a
scene that refers to a file by UID logs "invalid UID ... using text path instead" and then loads
the file by its path. The build tool removes the `uid="..."` from `[ext_resource]` lines of your
text scenes and resources as it packs them, so built mods load quietly. If you pack by hand,
do the same, or ignore the warning: nothing breaks. `.uid` sidecar files are not read by the
game; leave them out of the pack. Imported models (`.glb`) become binary scenes that keep their
UIDs; the warning there is harmless.

## Testing in the exported game

Run your mod in a downloaded copy of the game, not only from the source project: the exported
game has no script source text, which is where `extends` and replaced game files go wrong. Put the
built `.pck` in the mods folder, start the game, open **Settings → Mods** and read the log
(`[mods] <id> <version> (<file>)` means it runs).

## Rules that keep mods working

- Do not use `class_name` in mod scripts; it does not register from a pack. Use
  `preload("res://mods/<id>/thing.gd")` instead.
- Keep every file under `res://mods/<id>/`, except files you deliberately replace.
- Prefer hooks, merges and `super` calls over replacing files.
- Use full `res://` paths, never relative ones.
- Explicitly type values that come from a Variant (`var x: int = dict.get("x", 0)`): `var x := <Variant>` fails to parse.
- Store your data in `Mods.state(id)` or `Mods.data_folder(id)`, never in the game's own keys.
- Test with a fresh world and with an existing save, then with your mod switched off again.
- A scenario mod changes which saves load (see "Scenario mods"): tell your players to keep it on
  for its worlds, and never change its scenario `id`.
