"""Runs UI/Contribute.lua with a stubbed WoW API and feeds its JSON to the Python tools."""

import json
from pathlib import Path

from lupa import LuaRuntime

from build_data import load_recorded
from ingest_submission import validate, validate_submission

CONTRIBUTE = Path(__file__).resolve().parent.parent / "RareCodex" / "UI" / "Contribute.lua"

# Map 1414 behaves as if normalized (x, y) were world (x * 1000, y * 1000) on instance 1.
STUBS = """
local Vec = {}
Vec.__index = Vec
function Vec:GetXY() return self.x, self.y end
function CreateVector2D(x, y) return setmetatable({ x = x, y = y }, Vec) end
C_Map = {
    GetWorldPosFromMapPos = function(mapID, pos)
        if mapID ~= 1414 then return nil end
        return 1, CreateVector2D(pos.x * 1000, pos.y * 1000)
    end,
}
C_AddOns = { GetAddOnMetadata = function() return "0.2.0" end }
GetBuildInfo = function() return "1.60.1", "70959", "Nov 13 2026", 16001 end
GetLocale = function() return "esES" end
hooksecurefunc = function() end
"""


def load_contribute(lua_db: str):  # noqa: ANN201 - lupa table
    lua = LuaRuntime()
    lua.execute(STUBS)
    ns = lua.eval(
        "{ L = setmetatable({}, { __index = function(_, k) return k end }), On = function() end }"
    )
    lua.execute(f"__db = {lua_db}")
    ns.db = lua.globals().__db
    load = lua.eval("function(src) return load(src, 'Contribute.lua') end")
    load(CONTRIBUTE.read_text(encoding="utf-8"))("RareCodex", ns)
    return lua, ns.Contribute


def export(lua_db: str, include_shared: bool = False) -> str:
    lua, contribute = load_contribute(lua_db)
    return contribute.BuildJson(contribute.PendingIDs(include_shared))


DB = """{ axisSwapped = false, unknown = {
    [900001] = { name = 'Eck\\'alom "the" \\\\ one', level = 27, elite = true, sightings = {
        { mapID = 1414, x = 0.5, y = 0.25 },
        { mapID = 1414, x = 0.501, y = 0.25 },  -- 1 yard away: same spawn
        { mapID = 1414, x = 0.6, y = 0.25 },
        { mapID = 9999, x = 0.1, y = 0.1 },     -- unknown map: dropped
    } },
    [900002] = { name = 'Plain', sightings = {} },
    [900003] = { name = 'Shared', shared = true,
                 sightings = { { mapID = 1414, x = 0.1, y = 0.1 } } },
} }"""


def test_export_has_metadata_and_only_unshared_rares() -> None:
    document = json.loads(export(DB))
    assert document["addon"] == "0.2.0"
    assert document["game"] == "1.60.1 70959"
    assert document["locale"] == "esES"
    assert [r["id"] for r in document["rares"]] == [900001, 900002]


def test_export_can_include_shared_rares() -> None:
    document = json.loads(export(DB, include_shared=True))
    assert [r["id"] for r in document["rares"]] == [900001, 900002, 900003]


def test_export_round_trips_into_the_generator(tmp_path: Path) -> None:
    path = tmp_path / "submission.json"
    path.write_text(export(DB), encoding="utf-8")
    rare = load_recorded(path)[900001]
    assert rare["name"] == 'Eck\'alom "the" \\ one'
    assert rare["level"] == (27, 27) and rare["elite"] is True
    spawns = [(s["map"], s["x"], s["y"]) for s in rare["spawns"]]  # type: ignore[union-attr]
    assert spawns == [(1, 500.0, 250.0), (1, 600.0, 250.0)]


def test_export_passes_submission_validation() -> None:
    rares = validate(json.loads(export(DB)))
    assert [r["id"] for r in rares] == [900001, 900002]


def test_export_respects_swapped_axes() -> None:
    db = """{ axisSwapped = true, unknown = {
        [1] = { name = 'A', sightings = { { mapID = 1414, x = 0.5, y = 0.25 } } },
    } }"""
    spawn = json.loads(export(db))["rares"][0]["spawns"][0]
    assert spawn[1:] == [250.0, 500.0]


def test_chat_link_uses_addon_link_type() -> None:
    _, contribute = load_contribute("{ unknown = {} }")
    assert "|Haddon:RareCodex:contribute|h" in contribute.ChatLink()


def test_export_includes_tracks_in_world_coordinates() -> None:
    db = """{ axisSwapped = false, unknown = {
        [1] = { name = 'Walker', sightings = { { mapID = 1414, x = 0.5, y = 0.25 } },
                tracks = {
                    { mapID = 1414, points = { 0.5, 0.25, 0.51, 0.25, 0.52, 0.26 } },
                    { mapID = 9999, points = { 0.1, 0.1, 0.2, 0.2 } },  -- unknown map: dropped
                    { mapID = 1414, points = { 0.3, 0.3 } },  -- single point: dropped
                } },
    } }"""
    rare = json.loads(export(db))["rares"][0]
    assert rare["tracks"] == [[1, 500.0, 250.0, 510.0, 250.0, 520.0, 260.0]]
    assert validate({"rares": [rare]})[0]["tracks"] == rare["tracks"]


def test_loot_export_sends_only_kills_not_shared_yet() -> None:
    db = """{ unknown = {}, npcs = {
        [3736] = { kills = 5, loot = { [2592] = 2, [4606] = 3 },
                   shared = { kills = 2, loot = { [2592] = 2, [4606] = 1 } } },
        [100] = { kills = 1, loot = {}, shared = { kills = 1, loot = {} } },  -- all shared
    } }"""
    lua, contribute = load_contribute(db)
    document = json.loads(contribute.BuildJson(lua.table(), contribute.PendingLoot()))
    assert document["kills"] == [{"id": 3736, "kills": 3, "loot": {"4606": 2}}]
    assert validate_submission(document)[1] == document["kills"]
