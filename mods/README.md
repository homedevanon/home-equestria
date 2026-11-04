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

**Settings → Mods** lists every mod with its name, version and author, plus an On/Off switch.
A mod that only runs an entry script switches on and off at once. A mod that extends game
scripts or merges data switches the next time the game starts. Mods load in file name order, after the
game's own data, so a mod named `zz_...` loads after one named `aa_...` and wins when both change
the same thing.

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
	"extends": ["res://mods/more_cakes/ext/pony_locomotion.gd"]
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

## Ways to change the game

Use the first way that does the job. They are ordered from sturdiest to most fragile across game
updates.

### 1. Entry script and hooks

`entry` is a script that extends `Node`. The game adds it under the `Mods` autoload at start-up,
before the title screen, and it lives until the game quits. From it, everything in the scene
tree is reachable, and `Mods` gives you stable shortcuts:

| Call or signal | What it does |
| --- | --- |
| `Mods.world_ready(game)` | Signal: a world finished loading. `game` is `res://world/game.gd` and exposes `player`, `world_context` and the game's other systems. |
| `Mods.world_closed(game)` | Signal: the world is being left. |
| `Mods.player_ready(player)` | Signal: the player's body exists in the world. |
| `Mods.on_node(matcher, callback)` | Calls `callback(node)` for every matching node, those already there and every one that enters the tree later, once ready. `matcher` is a script path (matches that script and anything extending it), `"group:<name>"`, `"class:<Godot class>"`, or a `Callable(node) -> bool`. |
| `Mods.state(id)` | Your mod's section of the current world's save, a `Dictionary`. Change it, then call `Mods.save_changed()`. Empty before a world loads. A removed mod's section is kept and does no harm. |
| `Mods.data_folder(id)` | `user://mods/data/<id>/` for your own files outside any world. |
| `Mods.list()`, `Mods.is_active(id)` | Which mods are loaded, so mods can work together. |
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

### 4. Replace a game file

Any file in the pack at a game path, such as `res://world/ui/fonts/CelestiaMediumRedux.ttf`,
replaces the game's file. This is the most fragile option: the next game update may change that
file and your copy then breaks or undoes the update. Two mods replacing the same file cannot
both win.

### AI prompts and personas

Plain text prompt overrides need no pack: **Settings → AI Settings** has a folder for persona
and prompt files, and **Settings → Prompts** edits any prompt in game. A pack can also replace or
merge prompt files like any other data.

## Rules that keep mods working

- Do not use `class_name` in mod scripts; it does not register from a pack. Use
  `preload("res://mods/<id>/thing.gd")` instead.
- Keep every file under `res://mods/<id>/`, except files you deliberately replace.
- Prefer hooks, merges and `super` calls over replacing files.
- Use full `res://` paths, never relative ones.
- Explicitly type values that come from a Variant (`var x: int = dict.get("x", 0)`): `var x := <Variant>` fails to parse.
- Store your data in `Mods.state(id)` or `Mods.data_folder(id)`, never in the game's own keys.
- Test with a fresh world and with an existing save, then with your mod switched off again.
