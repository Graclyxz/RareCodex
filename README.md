# RareCodex

> **Status: alpha.** Built and tested for **WoW Forever** (client 1.60.1, interface `16001`).

RareCodex is a World of Warcraft addon about **rare mobs themselves**, not just their loot.
Rare-tracking addons usually answer "what can it drop?". RareCodex also answers
**"what is it, where does it walk, and how does it fight?"**, so you can recognize a rare on
sight, intercept its patrol and know what to expect before you pull it.

## Features

- **3D model viewer**: rotate and zoom the rare's model to recognize it in the world.
- **Abilities and behavior**: spells with in-game tooltips, plus notes such as
  "flees at 15% health" or "melee only".
- **Patrol routes on the map**: exact waypoint paths drawn as orange lines and wander areas
  as yellow circles. Hovering a pin highlights its route.
- **Loot with drop chances**: every item with its estimated drop rate. Random world drops are
  summarized by quality, and the rare/epic ones are listed item by item.
- **Personal stats**: last time seen, kill count and what you have looted from each rare.
- **Alerts**: sound and on-screen warning when a rare shows up on your minimap.
- **Community data**: rares that are not in the database yet (new WoW Forever content) are
  recorded with their location, and a clickable chat message guides you to share them so
  they are added for everyone.
- **Clean map**: pins on zone maps by default; continent and world maps are optional and
  show pins only, never patrol lines.
- **Localized**: the interface is available in English and Spanish (esES/esMX); names,
  spells and items come from the game client, so they appear in your client's language.

## Installation

1. Download `RareCodex-<version>.zip` from the
   [Releases](../../releases) page.
2. Extract it into `World of Warcraft\_forever_\Interface\AddOns\`. You should end up with
   `AddOns\RareCodex\RareCodex.toc`.
3. Restart the game or type `/reload`.

## Usage

On the world map: **click** a rare pin to open its detail panel, **shift-click** to set a
waypoint. Settings are under *Options > AddOns > RareCodex*.

| Command | Action |
|---|---|
| `/rc <name or npcID>` | Open the detail panel for a rare |
| `/rc config` | Open the options panel |
| `/rc show zone\|continent\|world` | Toggle pins per map type (default: zone maps only) |
| `/rc paths` | Toggle patrol lines |
| `/rc alerts` | Toggle rare alerts |
| `/rc share` | Share rares recorded in game that are not in the database |
| `/rc check` | Verify the world-to-map coordinate conversion |
| `/rc swap` | Flip coordinate axes if pins appear in wrong places |

## Where the data comes from

The rare database (spawn points, patrol waypoints, abilities, loot tables and chances) is
generated from the open-source [CMaNGOS Classic DB](https://github.com/cmangos/classic-db).
It currently contains **331 open-world rares** and **99 exact patrol routes**.

- Drop chances and routes are **estimates** from that database. WoW Forever may differ,
  especially for content Blizzard has changed or added.
- Only facts are exported (IDs, coordinates, chances). Names, icons and tooltips are read
  from the game client at runtime.

## Known limitations (beta)

- Rares that only exist in WoW Forever are not in CMaNGOS. Players record their position,
  patrol route, level and loot (see below); their abilities must be added by hand.
- **Abilities cannot be recorded automatically.** WoW Forever (Midnight addon rules) hides
  which spell an NPC casts: in unit cast events and `UnitCastingInfo` the spell ID and name
  are secret values, in and out of combat, and registering `COMBAT_LOG_EVENT_UNFILTERED`
  raises `ADDON_ACTION_FORBIDDEN` (verified in game on client 1.60.1).

## Development

```
RareCodex/          # the addon itself (symlink this folder into your AddOns folder)
  Core.lua          # events, saved variables, helpers, slash commands
  Data/Rares.lua    # GENERATED - do not edit by hand
  Map/              # coordinate conversion, map pins, patrol overlay
  Detection/        # vignette/target detection, kill and loot tracking
  UI/               # pin tooltip, detail panel, options panel
tools/              # Python tools: data generator and release packager
tests/              # pytest suite (generator logic + Lua syntax checks)
```

Requirements: Python 3.12+ and [uv](https://docs.astral.sh/uv/).

```sh
uv sync                                  # install dev dependencies
uv run pytest                            # run tests
uv run ruff check tools tests            # lint
uv run python tools/package.py           # build dist/RareCodex-<version>.zip
uv run python tools/make_textures.py     # regenerate Media/*.tga route textures
```

### How shared rare data reaches the addon

Rares missing from the database are saved when they appear on a player's minimap (position)
or are targeted (level and rank). Addons cannot access the internet, so sharing is guided:

1. A clickable chat message (or `/rc share`) opens a window with three steps: open the
   [Share rare data](../../issues/new?template=rare-data.yml) form, copy the data, paste it.
2. The **Rare data submission** workflow validates the JSON (`tools/ingest_submission.py`),
   merges it into `data/forever_rares.json` and opens a pull request, or comments the
   errors on the issue. Each rare keeps the issue numbers that reported it.
3. A maintainer reviews and merges the pull request, then regenerates the database (next
   section). `--min-reports 2` only includes rares confirmed by two separate submissions.
   Rares already in CMaNGOS are skipped.

### Adding abilities by hand

Players can describe a new rare's abilities in the *Notes* field of their submission. A
maintainer looks up the spell IDs and adds them to the rare in `data/forever_rares.json`:

```json
{"id": 900001, "name": "...", "spells": [133, 9532], ...}
```

Submissions can never set `"spells"` themselves (the bot drops the field and keeps the
reviewed ones). For rares that also exist in CMaNGOS, these spells are added to the
database ones.

### Translations

Interface texts are written in English in the code as `L["English text"]`; each
`RareCodex/Locales/<locale>.lua` maps them to another language. `tests/test_locales.py`
fails if a text has no translation or a format specifier (`%s`, `%d`) does not match.

### Regenerating the rare database

1. `git clone --depth 1 https://github.com/cmangos/classic-db`
2. Decompress `Full_DB/ClassicDB_*.sql.gz` (no MySQL server needed)
3. `uv run python tools/build_data.py path/to/ClassicDB.sql`

## Contributing

- **Rare data**: play with the addon and use the chat link or `/rc share`.
- **Bugs**: open a [bug report](../../issues/new?template=bug_report.yml) with the BugSack error.
- **Translations**: see *Translations* above; every text must keep its `%s`/`%d` placeholders.

Pushing a `v*` tag runs the **Release** workflow: tests, version check against the TOC,
package and GitHub release (tags with a suffix such as `-alpha` become pre-releases).

## License

Copyright (C) 2026 Graclyxz and RareCodex contributors.

RareCodex is free software: you can redistribute it and/or modify it under the terms of the
**GNU General Public License version 3** as published by the Free Software Foundation.
It is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even
the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See
[LICENSE](LICENSE) for the full text.

Contributions (code, translations and rare data submitted by players) are accepted under the
same license.

The rare database is derived from [CMaNGOS Classic DB](https://github.com/cmangos/classic-db),
also licensed under GPL-3.0. World of Warcraft content and materials are trademarks and
copyrights of Blizzard Entertainment. This project is not affiliated with Blizzard.
