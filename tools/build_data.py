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
from collections.abc import Callable
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
    observed: bool = False  # chance measured by players in WoW Forever, not estimated


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
        # Every creature, not only rares: WoW Forever turns some classic named NPCs into rares,
        # and players report them by ID.
        self.templates = {int(t["Entry"]): t for t in db.rows("creature_template")}
        self.spawn_rows: dict[int, list[Row]] = defaultdict(list)
        for row in db.rows("creature"):
            if row["map"] in OPEN_WORLD_MAPS:
                self.spawn_rows[int(row["id"])].append(row)

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
    def entry(self, entry: int, elite: bool) -> dict[str, object] | None:
        """Full data for any creature with open-world spawns, or None without spawns."""
        tpl = self.templates.get(entry)
        rows = self.spawn_rows.get(entry)
        if tpl is None or not rows:
            return None
        items, world = self.loot_for(int(tpl["LootId"] or 0))
        spawn_list = []
        for s in rows:
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
        return {
            "name": str(tpl["Name"]),
            "level": (int(tpl["MinLevel"]), int(tpl["MaxLevel"])),
            "elite": elite,
            "display": int(tpl["ModelId1"]),
            "respawn": (int(rows[0]["spawntimesecsmin"]), int(rows[0]["spawntimesecsmax"])),
            "gold": (int(tpl["MinLootGold"]), int(tpl["MaxLootGold"])),
            "flee": self.flee_percent(entry),
            "spells": self.spells(tpl),
            "spawns": spawn_list,
            "loot": items,
            "world": world,
        }

    def build(self) -> dict[int, dict[str, object]]:
        out: dict[int, dict[str, object]] = {}
        for entry, tpl in sorted(self.templates.items()):
            if tpl["Rank"] in RARE_RANKS:
                rare = self.entry(entry, elite=tpl["Rank"] == RANK_RARE_ELITE)
                if rare:
                    out[entry] = rare
        return out


# --- Lua serialization -------------------------------------------------------
def lua_str(value: str) -> str:
    """Quoted Lua string literal. Control characters become \\ddd escapes, so any input
    (including hand-edited data) yields valid Lua that cannot break out of the string."""
    out = []
    for char in value:
        if char in ('"', "\\"):
            out.append("\\" + char)
        elif ord(char) < 32 or ord(char) == 127:
            out.append(f"\\{ord(char):03d}")
        else:
            out.append(char)
    return '"' + "".join(out) + '"'


def lua_num(value: float) -> str:
    if math.isclose(value, round(value)):
        return str(int(round(value)))
    return f"{value:.2f}".rstrip("0").rstrip(".")


def lua_chance(value: float) -> str:
    """Chances keep 3 significant digits so tiny world-drop odds don't round to 0."""
    return f"{value:.3g}"


def lua_item(i: LootItem) -> str:
    """{itemID, chance[, isQuestItem[, isObserved]]}"""
    fields = [str(i.item), lua_chance(i.chance)]
    if i.quest or i.observed:
        fields.append("true" if i.quest else "false")
    if i.observed:
        fields.append("true")
    return "{" + ",".join(fields) + "}"


def lua_items(items: list[LootItem]) -> str:
    return "{" + ",".join(lua_item(i) for i in items) + "}"


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
    if rare.get("forever"):
        parts.append(f"forever={rare['forever']}")
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
-- loot / items: {itemID, chancePercent, isQuestItem, measuredInForever}
-- forever: kills behind the measured chances (data/forever_loot.json)
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


Track = tuple[int, list[tuple[float, float]]]  # (map, [(x, y), ...]) in world coordinates

MIN_PATROL_LENGTH = 15.0  # yards; a track shorter than this is a standing rare, not a patrol
SAME_ROUTE_DISTANCE = 60.0  # yards; tracks this close to each other follow the same route
ATTACH_DISTANCE = 200.0  # yards; a recorded route this close to a database spawn belongs to it
SAME_SPAWN_DISTANCE = 25.0  # yards


def _distance(a: tuple[float, float], b: tuple[float, float]) -> float:
    return math.hypot(a[0] - b[0], a[1] - b[1])


def _track_length(points: list[tuple[float, float]]) -> float:
    return sum(_distance(a, b) for a, b in zip(points, points[1:], strict=False))


def _tracks_touch(a: Track, b: Track) -> bool:
    return a[0] == b[0] and any(_distance(p, q) < SAME_ROUTE_DISTANCE for p in a[1] for q in b[1])


def patrol_routes(tracks: list[Track]) -> list[Track]:
    """Tracks recorded by players, grouped by route (tracks that come close to each other);
    the longest track of each group stands for the route. Tracks too short to be a patrol
    are dropped (their first point is still a spawn sighting)."""
    moving = [t for t in tracks if _track_length(t[1]) >= MIN_PATROL_LENGTH]
    groups: list[list[Track]] = []
    for track in moving:
        touching = [g for g in groups if any(_tracks_touch(track, t) for t in g)]
        merged = [track] + [t for g in touching for t in g]
        groups = [g for g in groups if g not in touching] + [merged]
    return [max(g, key=lambda t: _track_length(t[1])) for g in groups]


def recorded_spawns(points: list[list[float]], tracks: list[Track]) -> list[dict[str, object]]:
    """Spawn entries for a rare known only from players: one per patrol route (its start,
    with the route as path) plus every sighting that is not on a route."""
    routes = patrol_routes(tracks)
    spawns: list[dict[str, object]] = [
        {"map": m, "x": pts[0][0], "y": pts[0][1], "wander": 0.0, "path": pts} for m, pts in routes
    ]
    for m, x, y in points:
        on_route = any(
            rm == m and any(_distance((x, y), p) < SAME_ROUTE_DISTANCE for p in rpts)
            for rm, rpts in routes
        )
        known = any(
            s["map"] == m and _distance((x, y), (s["x"], s["y"])) < SAME_SPAWN_DISTANCE  # type: ignore[arg-type]
            for s in spawns
        )
        if not on_route and not known:
            spawns.append({"map": int(m), "x": float(x), "y": float(y), "wander": 0.0, "path": []})
    return spawns


def attach_routes(rare: dict[str, object], tracks: list[Track]) -> None:
    """Give database spawns without a path the routes players recorded near them; routes
    far from every database spawn become new spawns (WoW Forever may have moved the rare)."""
    spawns = rare["spawns"]
    assert isinstance(spawns, list)
    for m, pts in patrol_routes(tracks):
        nearest = min(
            (s for s in spawns if s["map"] == m and not s["path"]),
            key=lambda s: _distance((s["x"], s["y"]), pts[0]),
            default=None,
        )
        if nearest and _distance((nearest["x"], nearest["y"]), pts[0]) < ATTACH_DISTANCE:
            nearest["path"] = pts
            nearest["wander"] = 0.0
        else:
            spawns.append({"map": m, "x": pts[0][0], "y": pts[0][1], "wander": 0.0, "path": pts})


def _parse_tracks(raw: list[Any]) -> list[Track]:
    """[[map, x1, y1, ...], ...] (in-game export) or [{"issue", "points": [map, x1, y1, ...]},
    ...] (data file, which keeps who reported each track) -> [(map, [(x1, y1), ...]), ...]"""
    tracks: list[Track] = []
    for entry in raw:
        t = entry["points"] if isinstance(entry, dict) else entry
        coords = [float(v) for v in t[1:]]
        tracks.append((int(t[0]), list(zip(coords[0::2], coords[1::2], strict=True))))
    return tracks


def load_recorded(path: Path, min_reports: int = 1) -> dict[int, dict[str, object]]:
    """Rares recorded in game (data/forever_rares.json, or an in-game export).

    Each object: {"id", "name", "level" (int or null), "elite", "spawns": [[map, x, y], ...],
    "tracks": [[map, x1, y1, x2, y2, ...], ...], "reports": [issue numbers]}. Rares confirmed
    by fewer than min_reports submissions are left out; objects without "reports" (added by
    hand) count as one report. The raw tracks are kept under "tracks" for promotion.
    """
    if not path.is_file():
        return {}
    out: dict[int, dict[str, object]] = {}
    for rec in recorded_list(json.loads(path.read_text(encoding="utf-8"))):
        if len(rec.get("reports") or [None]) < min_reports:
            continue
        level = rec.get("level")
        tracks = _parse_tracks(rec.get("tracks") or [])
        out[int(rec["id"])] = {
            "name": str(rec["name"]),
            "level": (int(level), int(level)) if level else None,
            "elite": bool(rec.get("elite")),
            "unknown": True,
            "spells": [],
            "loot": [],
            "spawns": recorded_spawns(rec["spawns"], tracks),
            "tracks": tracks,
        }
    return out


Promoter = Callable[[int, bool], "dict[str, object] | None"]


def merge_recorded(
    rares: dict[int, dict[str, object]],
    recorded: dict[int, dict[str, object]],
    promote: Promoter | None = None,
) -> tuple[list[int], list[int]]:
    """Add recorded rares to rares. Returns (promoted, skipped).

    - Already a rare in the database: skipped.
    - A non-rare creature in the database (WoW Forever made it a rare): promoted, i.e. built
      from the database by promote(npc_id, elite) with the players' routes attached.
    - Unknown to the database: added from the recorded data; skipped without spawns.
    """
    promoted, skipped = [], []
    for npc_id, rare in sorted(recorded.items()):
        tracks = rare.pop("tracks", [])
        assert isinstance(tracks, list)
        if npc_id in rares:
            skipped.append(npc_id)
            continue
        full = promote(npc_id, bool(rare["elite"])) if promote else None
        if full is not None:
            attach_routes(full, tracks)
            rares[npc_id] = full
            promoted.append(npc_id)
        elif rare["spawns"]:
            rares[npc_id] = rare
        else:
            skipped.append(npc_id)
    return promoted, skipped


MIN_NEW_ITEM_DROPS = 2  # an item the database lacks must be seen this often to be listed


def load_loot(path: Path) -> dict[int, tuple[int, dict[int, int]]]:
    """data/forever_loot.json -> {npcID: (kills, {itemID: times dropped})}."""
    if not path.is_file():
        return {}
    raw = json.loads(path.read_text(encoding="utf-8"))
    return {
        int(npc): (int(s["kills"]), {int(item): int(c) for item, c in s["loot"].items()})
        for npc, s in raw.items()
    }


def apply_forever_loot(
    rares: dict[int, dict[str, object]],
    stats: dict[int, tuple[int, dict[int, int]]],
    min_kills: int,
) -> list[int]:
    """Replace estimated chances with the ones players measured in WoW Forever.

    Rares without a database loot table use the measurements from the first kill. Rares
    with one need min_kills first: with few kills a measured chance is mostly noise. Items
    the database lacks are added once seen MIN_NEW_ITEM_DROPS times, which keeps one-off
    random world drops out. Database items nobody saw keep their estimate.
    """
    applied = []
    for npc_id, rare in rares.items():
        if npc_id not in stats:
            continue
        kills, counts = stats[npc_id]
        loot = rare["loot"]
        assert isinstance(loot, list)
        no_table = not loot
        if kills <= 0 or (not no_table and kills < min_kills):
            continue
        by_item = {i.item: i for i in loot}
        for item, count in counts.items():
            chance = 100.0 * count / kills
            if item in by_item:
                by_item[item].chance, by_item[item].observed = chance, True
            elif no_table or count >= MIN_NEW_ITEM_DROPS:
                loot.append(LootItem(item, chance, observed=True))
        loot.sort(key=lambda i: -i.chance)
        rare["forever"] = kills
        applied.append(npc_id)
    return applied


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
        "--loot",
        type=Path,
        default=root / "data" / "forever_loot.json",
        help="kill and loot counts shared by players",
    )
    parser.add_argument(
        "--min-kills",
        type=int,
        default=20,
        help="kills a known rare needs before its measured chances replace the estimates",
    )
    parser.add_argument(
        "--min-reports",
        type=int,
        default=1,
        help="independent submissions a recorded rare needs before it is included",
    )
    args = parser.parse_args()
    builder = Builder(SqlDump(args.dump, TABLES))
    rares = builder.build()
    recorded = load_recorded(args.recorded, args.min_reports)
    promoted, skipped = merge_recorded(rares, recorded, builder.entry)
    if promoted:
        print(f"Promoted to rares with full database data: {promoted}")
    if skipped:
        print(f"Skipped recorded rares already in the database or without spawns: {skipped}")
    added = len(recorded) - len(promoted) - len(skipped)
    print(f"Added {added} rares known only from players")
    measured = apply_forever_loot(rares, load_loot(args.loot), args.min_kills)
    if measured:
        print(f"Drop chances measured in WoW Forever for: {measured}")
    write_lua(rares, args.output)
    paths = sum(1 for r in rares.values() for s in r["spawns"] if s["path"])  # type: ignore[attr-defined]
    print(f"Wrote {len(rares)} rares ({paths} patrol paths) to {args.output}")


if __name__ == "__main__":
    main()
