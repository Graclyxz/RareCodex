"""Runs the sorting of UI/RareList.lua outside the game client."""

from pathlib import Path

from lupa import LuaRuntime

ADDON = Path(__file__).resolve().parent.parent / "RareCodex"
HOUR = 3600


def sorted_names(states: str) -> list[str]:
    lua = LuaRuntime()
    lua.execute(
        """
        CreateFrame = function()
            return { RegisterEvent = function() end, SetScript = function() end }
        end
        SlashCmdList = {}
        """
    )
    ns = lua.eval("{ L = setmetatable({}, { __index = function(_, k) return k end }) }")
    load = lua.eval("function(src, name) return load(src, name) end")
    for name in ("Core.lua", "UI/RareList.lua"):
        load((ADDON / name).read_text(encoding="utf-8"), name)("RareCodex", ns)
    lua.globals().ns = ns
    lua.execute(
        f"""
        local respawn = {{ {HOUR}, {3 * HOUR} }}
        ns.Rares = {{
            [1] = {{ name = "Dead", level = {{ 5, 5 }}, respawn = respawn }},
            [2] = {{ name = "Window", level = {{ 30, 30 }}, respawn = respawn }},
            [3] = {{ name = "Unknown high", level = {{ 20, 20 }}, respawn = respawn }},
            [4] = {{ name = "Unknown low", level = {{ 10, 10 }}, respawn = respawn }},
            [5] = {{ name = "Seen", level = {{ 40, 40 }}, respawn = respawn }},
        }}
        ns.db = {{ npcs = {states} }}
        ns.GetName = function(id) return ns.Rares[id].name end
        """
    )
    groups = lua.eval("{ {npcID=1}, {npcID=2}, {npcID=3}, {npcID=4}, {npcID=5} }")
    entries = ns.RareList.SortedEntries(groups, 10 * HOUR)
    return [entry.name for entry in entries.values()]


def test_order_by_status_then_level() -> None:
    states = f"""{{
        [1] = {{ lastDeath = {10 * HOUR - 600} }},
        [2] = {{ lastDeath = {8 * HOUR} }},
        [5] = {{ lastSeen = {10 * HOUR - 60} }},
    }}"""
    assert sorted_names(states) == ["Seen", "Window", "Unknown low", "Unknown high", "Dead"]


def test_without_any_data_sorted_by_level() -> None:
    assert sorted_names("{}") == ["Dead", "Unknown low", "Unknown high", "Window", "Seen"]
