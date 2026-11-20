"""Runs the gear list of UI/DetailPanel.lua outside the game client."""

from pathlib import Path

import pytest
from lupa import LuaRuntime

PANEL = Path(__file__).resolve().parent.parent / "RareCodex" / "UI" / "DetailPanel.lua"


@pytest.fixture(scope="module")
def gear_list():  # noqa: ANN201 - Lua function
    lua = LuaRuntime()
    lua.execute("StaticPopupDialogs = {}; CLOSE = 'Close'")
    ns = lua.eval(
        """{
        L = setmetatable({}, { __index = function(_, k) return k end }),
        On = function() end,
        Pools = {
            [100] = { 4, 11, 12 },       -- 4 items in the pool, 2 of them gear
            [200] = { 2, 12 },           -- item 12 is in both pools
            [300] = { 10, 31 },
        },
    }"""
    )
    load = lua.eval("function(src) return load(src, 'DetailPanel.lua') end")
    load(PANEL.read_text(encoding="utf-8"))("RareCodex", ns)
    return lua, ns.DetailPanel._GearList


def entries(lua: LuaRuntime, gear_list, rare: str) -> list[tuple[int, float, int]]:  # noqa: ANN001
    result = gear_list(lua.eval(rare))
    return [(e.itemID, e.chance, e.quality) for e in result.values()]


def test_chances_split_per_pool_and_add_up_across_pools(gear_list) -> None:  # noqa: ANN001
    lua, fn = gear_list
    got = entries(lua, fn, "{ world = { { q = 2, pools = { 100, 40, 200, 10 } } } }")
    assert got == [(12, pytest.approx(15.0), 2), (11, pytest.approx(10.0), 2)]


def test_better_quality_first_and_missing_pools_ignored(gear_list) -> None:  # noqa: ANN001
    lua, fn = gear_list
    rare = """{ world = {
        { q = 2, pools = { 100, 40 } },
        { q = 4, pools = { 300, 1, 999, 50 } },
    } }"""
    got = entries(lua, fn, rare)
    assert [item for item, _, _ in got] == [31, 11, 12]
    assert got[0] == (31, pytest.approx(0.1), 4)


def test_rare_without_world_drops_has_no_gear(gear_list) -> None:  # noqa: ANN001
    lua, fn = gear_list
    assert entries(lua, fn, "{}") == []
