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
- **Unknown rare recording**: rares that are not in the database yet (new WoW Forever
  content) are saved with their location, so future data updates can include them.
- **Clean map**: pins on zone maps by default; continent and world maps are optional and
  show pins only, never patrol lines.
- **Localized automatically**: names, spells and items come from the game client, so they
  appear in your client's language.

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

## Known limitations (alpha)

- Rares added by WoW Forever are not in the database yet; the addon records them when seen.
- Interface texts (labels, buttons) are English only for now; game data is localized.
- Kills are counted when you loot the corpse.

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
```

### Regenerating the rare database

1. `git clone --depth 1 https://github.com/cmangos/classic-db`
2. Decompress `Full_DB/ClassicDB_*.sql.gz` (no MySQL server needed)
3. `uv run python tools/build_data.py path/to/ClassicDB.sql`

## License

No license has been chosen yet. Game data is derived from
[CMaNGOS Classic DB](https://github.com/cmangos/classic-db), which is GPL-3.0.
World of Warcraft content and materials are trademarks and copyrights of Blizzard
Entertainment. This project is not affiliated with Blizzard.
