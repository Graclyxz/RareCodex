"""Generate RareCodex/Data/Rares.lua from a CMaNGOS Classic world database dump.

Usage:
    python tools/build_data.py <ClassicDB.sql> [-o RareCodex/Data/Rares.lua]

Only facts are exported (IDs, coordinates, chances); localized names, icons and
tooltips are resolved in-game through the WoW API.
"""

from __future__ import annotations

import argparse
import json
import math
import re
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from sqldump import Row, SqlDump

OPEN_WORLD_MAPS = {0, 1}  # Eastern Kingdoms, Kalimdor
RANK_RARE_ELITE = 2
RANK_RARE = 4
RARE_RANKS = {RANK_RARE_ELITE, RANK_RARE}

AI_ACTION_CAST = 11
AI_ACTION_FLEE = 25
AI_ACTION_SLOTS = (1, 2, 3)

MOVEMENT_WAYPOINT = 2
# References with more items than this are summarized, not listed item by item.
MAX_LISTED_REFERENCE_ITEMS = 40
MIN_LISTED_QUALITY = 3  # rare (blue) and above

TABLES = {
    "creature_template",
    "creature",
    "creature_movement",
    "creature_movement_template",
    "creature_loot_template",
    "reference_loot_template",
    "creature_ai_scripts",
    "creature_template_spells",
    "creature_spell_list",
    "item_template",
}


@dataclass
class LootItem:
    item: int
    chance: float
    quest: bool = False


@dataclass
class WorldDrop:
    quality: int
    chance: float
    count: int
    items: list[LootItem] = field(default_factory=list)


def resolve_chances(rows: list[Row]) -> list[tuple[Row, float]]:
    """Per-kill chance of each loot row, applying CMaNGOS group rules.

    Ungrouped rows roll independently. Inside a group exactly one entry can drop:
    explicit chances are used as-is and rows with chance 0 share what is left.
    """
    result: list[tuple[Row, float]] = []
    groups: dict[int, list[Row]] = defaultdict(list)
    for row in rows:
        group = int(row["groupid"] or 0)
        if group == 0:
            result.append((row, abs(float(row["ChanceOrQuestChance"] or 0))))
        else:
            groups[group].append(row)
    for members in groups.values():
        explicit = [r for r in members if float(r["ChanceOrQuestChance"] or 0) != 0]
        equal = [r for r in members if float(r["ChanceOrQuestChance"] or 0) == 0]
        used = sum(abs(float(r["ChanceOrQuestChance"] or 0)) for r in explicit)
        share = max(0.0, 100.0 - used) / len(equal) if equal else 0.0
        result.extend((r, abs(float(r["ChanceOrQuestChance"] or 0))) for r in explicit)
        result.extend((r, share) for r in equal)
    return result


def merge_world_drops(drops: list[WorldDrop]) -> list[WorldDrop]:
    """Merge pools of the same quality into one line, best quality first.

    Pools roll independently, so the merged chance is 1 - product(1 - p), not a sum.
    Items are only listed when every merged pool listed them.
    """
    by_quality: dict[int, list[WorldDrop]] = defaultdict(list)
    for drop in drops:
        by_quality[drop.quality].append(drop)
    merged: list[WorldDrop] = []
    for quality in sorted(by_quality, reverse=True):
        pools = by_quality[quality]
        miss = math.prod(1 - p.chance / 100 for p in pools)
        items = [i for p in pools for i in p.items] if all(p.items for p in pools) else []
        merged.append(
            WorldDrop(
                quality,
                (1 - miss) * 100,
                sum(p.count for p in pools),
                sorted(items, key=lambda i: -i.chance),
            )
        )
    return merged


class Builder:
    def __init__(self, db: SqlDump) -> None:
        self.db = db
        self.loot: dict[int, list[Row]] = defaultdict(list)
        for row in db.rows("creature_loot_template"):
            self.loot[int(row["entry"])].append(row)
        self.refs: dict[int, list[Row]] = defaultdict(list)
        for row in db.rows("reference_loot_template"):
            self.refs[int(row["entry"])].append(row)
        self.quality = {int(r["entry"]): int(r["Quality"]) for r in db.rows("item_template")}
        self.ai: dict[int, list[Row]] = defaultdict(list)
        for row in db.rows("creature_ai_scripts"):
            self.ai[int(row["creature_id"])].append(row)
        self.tpl_spells: dict[int, list[int]] = defaultdict(list)
        for row in db.rows("creature_template_spells"):
            self.tpl_spells[int(row["entry"])].extend(
                int(row[f"spell{i}"]) for i in range(1, 11) if row[f"spell{i}"]
            )
        self.spell_lists: dict[int, list[int]] = defaultdict(list)
        for row in db.rows("creature_spell_list"):
            self.spell_lists[int(row["Id"])].append(int(row["SpellId"]))
        self.paths_by_guid: dict[int, list[Row]] = defaultdict(list)
        for row in db.rows("creature_movement"):
            self.paths_by_guid[int(row["Id"])].append(row)
        self.paths_by_entry: dict[int, list[Row]] = defaultdict(list)
        for row in db.rows("creature_movement_template"):
            if int(row["PathId"]) == 0:
                self.paths_by_entry[int(row["Entry"])].append(row)

    # --- abilities -------------------------------------------------------
    def spells(self, tpl: Row) -> list[int]:
        entry = int(tpl["Entry"])
        found: list[int] = []
        for row in self.ai[entry]:
            for slot in AI_ACTION_SLOTS:
                if row[f"action{slot}_type"] == AI_ACTION_CAST:
                    found.append(int(row[f"action{slot}_param1"]))
        found += self.tpl_spells[entry]
        found += self.spell_lists[int(tpl["SpellList"] or 0)]
        return list(dict.fromkeys(s for s in found if s > 0))

    def flee_percent(self, entry: int) -> int | None:
        for row in self.ai[entry]:
            for slot in AI_ACTION_SLOTS:
                if row[f"action{slot}_type"] == AI_ACTION_FLEE:
                    match = re.search(r"(\d+)%", str(row["comment"] or ""))
                    return int(match.group(1)) if match else 0
        return None

    # --- loot ------------------------------------------------------------
    def loot_for(self, loot_id: int) -> tuple[list[LootItem], list[WorldDrop]]:
        items: list[LootItem] = []
        world: list[WorldDrop] = []
        for row, chance in resolve_chances(self.loot.get(loot_id, [])):
            if chance <= 0:
                continue
            ref = -int(row["mincountOrRef"])
            if ref > 0:
                world.append(self._world_drop(ref, chance))
            else:
                quest = float(row["ChanceOrQuestChance"] or 0) < 0
                items.append(LootItem(int(row["item"]), chance, quest))
        items.sort(key=lambda i: -i.chance)
        return items, merge_world_drops(world)

    def _world_drop(self, ref: int, chance: float) -> WorldDrop:
        resolved = [
            (row, c)
            for row, c in resolve_chances(self.refs.get(ref, []))
            if int(row["mincountOrRef"]) > 0
        ]
        qualities = [self.quality.get(int(r["item"]), 0) for r, _ in resolved]
        quality = max(set(qualities), key=qualities.count) if qualities else 0
        drop = WorldDrop(quality, chance, len(resolved))
        if quality >= MIN_LISTED_QUALITY and len(resolved) <= MAX_LISTED_REFERENCE_ITEMS:
            drop.items = sorted(
                (LootItem(int(r["item"]), chance * c / 100.0) for r, c in resolved),
                key=lambda i: -i.chance,
            )
        return drop

    # --- movement --------------------------------------------------------
    def path_for(self, spawn: Row) -> list[tuple[float, float]]:
        rows = self.paths_by_guid.get(int(spawn["guid"])) or self.paths_by_entry.get(
            int(spawn["id"]), []
        )
        rows = sorted(rows, key=lambda r: int(r["Point"]))
        return [(float(r["PositionX"]), float(r["PositionY"])) for r in rows]

    # --- assembly --------------------------------------------------------
    def build(self) -> dict[int, dict[str, object]]:
        rares = {
            int(t["Entry"]): t for t in self.db.rows("creature_template") if t["Rank"] in RARE_RANKS
        }
        spawns: dict[int, list[Row]] = defaultdict(list)
        for row in self.db.rows("creature"):
            if row["id"] in rares and row["map"] in OPEN_WORLD_MAPS:
                spawns[int(row["id"])].append(row)

        out: dict[int, dict[str, object]] = {}
        for entry in sorted(spawns):
            tpl = rares[entry]
            items, world = self.loot_for(int(tpl["LootId"] or 0))
            spawn_list = []
            for s in spawns[entry]:
                path = self.path_for(s) if s["MovementType"] == MOVEMENT_WAYPOINT else []
                spawn_list.append(
                    {
                        "map": int(s["map"]),
                        "x": float(s["position_x"]),
                        "y": float(s["position_y"]),
                        "wander": float(s["spawndist"]) if s["MovementType"] == 1 else 0.0,
                        "path": path,
                    }
                )
            out[entry] = {
                "name": str(tpl["Name"]),
                "level": (int(tpl["MinLevel"]), int(tpl["MaxLevel"])),
                "elite": tpl["Rank"] == RANK_RARE_ELITE,
                "display": int(tpl["ModelId1"]),
                "respawn": (
                    int(spawns[entry][0]["spawntimesecsmin"]),
                    int(spawns[entry][0]["spawntimesecsmax"]),
                ),
                "gold": (int(tpl["MinLootGold"]), int(tpl["MaxLootGold"])),
                "flee": self.flee_percent(entry),
                "spells": self.spells(tpl),
                "spawns": spawn_list,
                "loot": items,
                "world": world,
            }
        return out


# --- Lua serialization -------------------------------------------------------
def lua_str(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def lua_num(value: float) -> str:
    if math.isclose(value, round(value)):
        return str(int(round(value)))
    return f"{value:.2f}".rstrip("0").rstrip(".")


def lua_chance(value: float) -> str:
    """Chances keep 3 significant digits so tiny world-drop odds don't round to 0."""
    return f"{value:.3g}"


def lua_items(items: list[LootItem]) -> str:
    return (
        "{"
        + ",".join(
            f"{{{i.item},{lua_chance(i.chance)}{',true' if i.quest else ''}}}" for i in items
        )
        + "}"
    )


def to_lua(entry: int, rare: dict[str, object]) -> str:
    """Serialize one rare. level, display, respawn, gold, flee and world are optional
    (rares recorded in game only have a name, spawns and maybe a level)."""
    level = rare.get("level")
    respawn = rare.get("respawn")
    gold = rare.get("gold")
    spawns = rare["spawns"]
    world = rare.get("world") or []
    assert isinstance(spawns, list) and isinstance(world, list)
    parts = [
        f"name={lua_str(str(rare['name']))}",
        f"spells={{{','.join(map(str, rare['spells']))}}}",  # type: ignore[call-overload]
        f"loot={lua_items(rare['loot'])}",  # type: ignore[arg-type]
    ]
    if isinstance(level, tuple):
        parts.append(f"level={{{level[0]},{level[1]}}}")
    if rare.get("display"):
        parts.append(f"display={rare['display']}")
    if isinstance(respawn, tuple):
        parts.append(f"respawn={{{respawn[0]},{respawn[1]}}}")
    if rare.get("elite"):
        parts.append("elite=true")
    if isinstance(gold, tuple) and gold[1]:
        parts.append(f"gold={{{gold[0]},{gold[1]}}}")
    if rare.get("flee") is not None:
        parts.append(f"flee={rare['flee']}")
    if rare.get("unknown"):
        parts.append("unknown=true")
    spawn_parts = []
    for s in spawns:
        fields = [str(s["map"]), lua_num(s["x"]), lua_num(s["y"])]
        extra = []
        if s["wander"]:
            extra.append(f"wander={lua_num(s['wander'])}")
        if s["path"]:
            flat = ",".join(f"{lua_num(x)},{lua_num(y)}" for x, y in s["path"])
            extra.append(f"path={{{flat}}}")
        spawn_parts.append("{" + ",".join(fields + extra) + "}")
    parts.append("spawns={" + ",".join(spawn_parts) + "}")
    if world:
        parts.append(
            "world={"
            + ",".join(
                f"{{q={w.quality},c={lua_chance(w.chance)},n={w.count}"
                + (f",items={lua_items(w.items)}" if w.items else "")
                + "}"
                for w in world
            )
            + "}"
        )
    return f"D[{entry}]={{{','.join(parts)}}}"


HEADER = """\
-- GENERATED FILE - do not edit by hand. Run tools/build_data.py instead.
-- Sources: CMaNGOS Classic DB (GPL-3.0) and data/forever_rares.json (rares recorded in
-- game, marked unknown=true). Chances are estimates.
-- spawns: {instanceMapID, worldX, worldY, wander=yards, path={x1,y1,x2,y2,...}}
-- loot / items: {itemID, chancePercent, isQuestItem}
-- world: summarized world-drop pools {q=quality, c=chance, n=itemCount, items=...}
local _, ns = ...
local D = {}
ns.Rares = D
"""


def recorded_list(document: Any) -> list[dict[str, Any]]:  # parsed JSON is dynamic
    """The rare objects of a recorded-rares document: either a bare JSON array (the merged
    data file) or the in-game export object {"addon", "game", "locale", "rares": [...]}."""
    if isinstance(document, dict):
        document = document.get("rares", [])
    if not isinstance(document, list):
        raise ValueError("expected a list of rares or an object with a 'rares' list")
    return document


def load_recorded(path: Path, min_reports: int = 1) -> dict[int, dict[str, object]]:
    """Rares recorded in game (data/forever_rares.json, or an in-game export).

    Each object: {"id", "name", "level" (int or null), "elite", "spawns": [[map, x, y], ...],
    "reports": [issue numbers]}. Rares confirmed by fewer than min_reports submissions are
    left out; objects without "reports" (added by hand) count as one report.
    """
    if not path.is_file():
        return {}
    out: dict[int, dict[str, object]] = {}
    for rec in recorded_list(json.loads(path.read_text(encoding="utf-8"))):
        if len(rec.get("reports") or [None]) < min_reports:
            continue
        level = rec.get("level")
        out[int(rec["id"])] = {
            "name": str(rec["name"]),
            "level": (int(level), int(level)) if level else None,
            "elite": bool(rec.get("elite")),
            "unknown": True,
            "spells": [],
            "loot": [],
            "spawns": [
                {"map": int(m), "x": float(x), "y": float(y), "wander": 0.0, "path": []}
                for m, x, y in rec["spawns"]
            ],
        }
    return out


def merge_recorded(
    rares: dict[int, dict[str, object]], recorded: dict[int, dict[str, object]]
) -> list[int]:
    """Add recorded rares the database lacks; returns the IDs skipped as already known.
    Rares without any spawn point cannot be placed on the map and are skipped too."""
    skipped = []
    for npc_id, rare in sorted(recorded.items()):
        if npc_id in rares or not rare["spawns"]:
            skipped.append(npc_id)
        else:
            rares[npc_id] = rare
    return skipped


def write_lua(rares: dict[int, dict[str, object]], path: Path) -> None:
    lines = [HEADER] + [to_lua(e, r) for e, r in rares.items()]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dump", type=Path, help="CMaNGOS Classic DB .sql dump")
    parser.add_argument(
        "-o", "--output", type=Path, default=root / "RareCodex" / "Data" / "Rares.lua"
    )
    parser.add_argument(
        "--recorded",
        type=Path,
        default=root / "data" / "forever_rares.json",
        help="rares recorded in game and shared by players",
    )
    parser.add_argument(
        "--min-reports",
        type=int,
        default=1,
        help="independent submissions a recorded rare needs before it is included",
    )
    args = parser.parse_args()
    rares = Builder(SqlDump(args.dump, TABLES)).build()
    recorded = load_recorded(args.recorded, args.min_reports)
    skipped = merge_recorded(rares, recorded)
    if skipped:
        print(f"Skipped recorded rares already in the database or without spawns: {skipped}")
    print(f"Added {len(recorded) - len(skipped)} rares recorded in game")
    write_lua(rares, args.output)
    paths = sum(1 for r in rares.values() for s in r["spawns"] if s["path"])  # type: ignore[attr-defined]
    print(f"Wrote {len(rares)} rares ({paths} patrol paths) to {args.output}")


if __name__ == "__main__":
    main()
