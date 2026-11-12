# Prompt for AI agents building a Home: Equestria mod

You are building a mod for Home: Equestria, a Godot 4.5 GDScript VR and desktop pony life-sim.
The result is one standalone `.pck` file that players drop into their mods folder. Read
`res://mods/README.md` first: it defines the mod format, the `Mods` hooks and the build command.
This file adds the working rules.

## Your task, in order

1. Ask the user what the mod should do if that is unclear. Pick a mod id: lower-case letters,
   digits and `_`, unique (for example `rarity_hats`).
2. Find the game code that owns the behaviour. Search the source: `world/` holds gameplay,
   `player/` input and the player's body, `autoload/` shared state such as `Settings`. Read the
   owning script fully before changing anything. `docs/` (when present) has a codebase guide.
3. Choose the sturdiest way that works, in this order: entry script with `Mods` hooks; JSON
   merge into game data; a script extension that calls `super`; replacing a game file. Say which
   you chose and why.
4. Write everything under `res://mods/<id>/`: `mod.json`, scripts, scenes, assets. Do not edit
   any game file outside that folder. Game files you replace on purpose are copied into the
   mod's pack at the game's path, never edited in place.
5. Make sure the project has its source data: the `source-data` zips from the GitHub release of
   the same game version, unzipped into the project root. If pony bodies, terrain or grass are
   missing, ask the user to download and unzip them; do not work around missing assets.
   Then import and build:
   ```
   godot --headless --xr-mode off --path <project> --editor --quit
   godot --headless --xr-mode off --path <project> --script res://tools/modding/build_mod.gd -- <id>
   ```
   Build success prints `MOD_BUILT <path>`. Any `MOD_BUILD_FAILED` line says what is wrong.
6. Test. Run the game with the mod unpacked (`godot --xr-mode off --path <project> -- --mod-src <id>`)
   or with the built pack in the mods folder. Read the log: `[mods] <id> <version>` means it
   loaded. `[mods] <id> not loaded: ...` says why it did not. Fix every script error the log shows.
   Then check the behaviour in game, start a fresh world and load an existing one, and confirm the
   game still runs with the mod switched off in Settings → Mods. If the user has a downloaded
   (exported) copy of the game, test the built `.pck` there too: exported games keep their scripts
   as compiled tokens, which is where script extensions and replaced game files behave differently.
7. Tell the user where the `.pck` is, what it changes, how you tested it, and anything you could
   not test (for example VR or Quest).

## GDScript and Godot rules

- Godot 4.5 GDScript, tabs for indentation, snake_case names, UPPER_SNAKE_CASE constants.
- No `class_name` in mod scripts: global classes do not register from a pack. Use
  `preload("res://mods/<id>/file.gd")`.
- Type values read from a Variant explicitly: `var count: int = data.get("count", 0)`.
  `var count := data.get("count", 0)` is a parse error.
- Check optional nodes and properties before use: `node.get("prop")`, `has_method()`,
  `is_instance_valid()`. Game internals change between versions; fail quietly, never crash.
- An entry script is a `Node`. Use `_ready`, signals and `Mods.on_node`. Avoid heavy work in
  `_process`: ponies, grass and the world are already expensive, and players run VR at 72-90 FPS.
- A coroutine that waits in a loop must stop when the world closes: check
  `is_instance_valid(...)` and `is_inside_tree()` after every `await`.
- Save data goes in `Mods.state("<id>")`, then `Mods.save_changed()`. Never add keys to the
  game's own save sections.
- A script extension must call `super(...)` in every function it overrides, unless replacing
  the behaviour is the point of the mod.
- Physics bodies take the scale of their parent when they enter the tree: set a body's
  transform before `add_child`.
- A script extension starts with `extends "res://<game script>.gd"` on its own line, full path,
  quoted. Never extend a `.gdc` path. Ship extensions as `.gd` source (the build tool does). If
  the override does not compile against the player's game, the mod is switched off with "could
  not extend <path> in this build"; check the log for the compiler's message.
- If your mod needs another mod, declare it in `mod.json`: `"depends": {"other_id": ">=1.2.0"}`.
  Read the other mod's state through `Mods.is_active(id)` and `Mods.pack_rows()`, never by
  reaching into its files.
- Do not ship `.uid` files, and do not rely on `uid://` references between your own files: the
  game does not know your UIDs. The build tool strips them from `[ext_resource]` lines of text
  scenes and resources; refer to your files by `res://mods/<id>/...` paths in code.
- Unknown keys in `mod.json` are ignored; a known key with the wrong shape (`scenario`, `depends`,
  `patches`, `extends`) stops the mod. Keep `version` a dotted number (`1.2.0`): bundled-mod
  updates, `depends` and patch packs compare it by numbers.

## Scenario mods

If the mod changes how a new world starts (an alternate Equestria, another opening), make it a
scenario mod: read `res://mods/README.md` "Scenario mods" and copy `res://mods/example_scenario/`.

- Declare `"scenario": {"id", "name", ...}` in `mod.json`. The `id` is stamped into every world
  and save of the scenario: never rename it after release.
- Put the start in the start node (`prepare(game, resumed)`, `signal finished`) and use the
  `game.arrival` hooks (`end_opening`, `place_player`, `place_at_golden_oak`, `skip_to_free_home`,
  `choose_form`). Do not copy or replace `world/life/arrival_story.gd`, `world/game.gd` or
  `world/game_saves.gd`.
- `prepare` runs for new and continued worlds: only set up a brand-new world when `resumed` is
  false, and keep any per-world flags in `"mods": {"<id>": {...}}` (initial_state or
  `Mods.state(id)`).
- Every coroutine wait must stop when the world is being left (`if not await ...: return`).
- Test both directions: with the mod on, older saves are refused ("Turn off ..."); with it off,
  its saves are refused ("Needs ..."). Only one scenario mod runs at a time.

## Game rules mods should keep

- Interactions are physical: books open with text on pages, items are objects in the world held
  in hands. Menus are only for settings and saves. Prefer an object the player handles over a
  GUI panel.
- The game runs on desktop and in VR (PC and Quest). Anything a player must do needs a desktop
  key or mouse action and a VR hand action, or should say it is desktop only.
- Pony poses must stay inside the game's joint limits: rotate bones, never stretch them.
- Young ponies (fillies and colts) have no romance of any kind.
- The AI ponies speak through prompt text with action tags such as `[follow: player]`. To add a
  pony behaviour the AI can choose, study `world/ai/pony_action_schema.gd` and the director
  scripts in `world/ai/` before extending them.

## Do not

- Do not make network requests, read or write files outside `user://` and `res://`, run
  programs, or collect anything about the player. Players trust mods with their computer.
- Do not copy assets you have no right to share. Credit your sources in `mod.json` "description"
  or in the files you ship.
- Do not edit `res://tools/modding/build_mod.gd` or `res://world/modding/` to make your mod work;
  the players' game will not have your edits.
- Do not replace `world/game.gd` or `world/game_saves.gd`; extend them. A stale copy of either
  breaks new worlds and saves after the next game update, and Settings → Mods warns players about
  any pack that does.
- Do not write into the game's install folder or its `mods/bundled/` folder, and do not download
  or install other packs. Bundled mods and their updates belong to the game.
