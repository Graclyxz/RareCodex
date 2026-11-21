"""Runs the respawn status logic of Core.lua outside the game client."""

from pathlib import Path

import pytest
from lupa import LuaRuntime

CORE = Path(__file__).resolve().parent.parent / "RareCodex" / "Core.lua"
HOUR = 3600
RARE = "{ respawn = { 1 * 3600, 3 * 3600 } }"


@pytest.fixture(scope="module")
def lua() -> LuaRuntime:
    runtime = LuaRuntime()
    runtime.execute(
        """
        CreateFrame = function()
            return { RegisterEvent = function() end, SetScript = function() end }
        end
        SlashCmdList = {}
        """
    )
    ns = runtime.eval("{ L = setmetatable({}, { __index = function(_, k) return k end }) }")
    load = runtime.eval("function(src) return load(src, 'Core.lua') end")
    load(CORE.read_text(encoding="utf-8"))("RareCodex", ns)
    runtime.globals().ns = ns
    return runtime


def status(lua: LuaRuntime, state: str, now: int, rare: str = RARE) -> dict | None:
    result = lua.eval(f"ns.RareStatus({rare}, {state}, {now})")
    return dict(result) if result else None


def test_nothing_known(lua: LuaRuntime) -> None:
    assert status(lua, "nil", 0) is None
    assert status(lua, "{}", 0) is None


def test_dead_until_minimum_respawn(lua: LuaRuntime) -> None:
    got = status(lua, "{ lastDeath = 0, lastSeen = 0 }", HOUR // 2)
    assert got == {"kind": "dead", "from": HOUR // 2, "to": 2.5 * HOUR}


def test_window_between_minimum_and_maximum(lua: LuaRuntime) -> None:
    got = status(lua, "{ lastDeath = 0 }", 2 * HOUR)
    assert got == {"kind": "window", "to": HOUR}


def test_unknown_after_maximum_respawn(lua: LuaRuntime) -> None:
    assert status(lua, "{ lastDeath = 0 }", 4 * HOUR) is None


def test_seen_alive_recently(lua: LuaRuntime) -> None:
    assert status(lua, "{ lastSeen = 1000 }", 1060) == {"kind": "seen", "ago": 60}
    assert status(lua, "{ lastSeen = 1000 }", 1000 + 10 * 60) is None


def test_sighting_right_after_death_is_the_corpse(lua: LuaRuntime) -> None:
    got = status(lua, "{ lastDeath = 0, lastSeen = 120 }", 180)
    assert got["kind"] == "dead"


def test_sighting_long_after_death_means_it_respawned(lua: LuaRuntime) -> None:
    got = status(lua, "{ lastDeath = 0, lastSeen = 1800 }", 1860)
    assert got == {"kind": "seen", "ago": 60}
    # Seen alive a while ago: no longer dead, and too old to glow.
    assert status(lua, "{ lastDeath = 0, lastSeen = 1800 }", 3000) is None


def test_rare_without_respawn_data(lua: LuaRuntime) -> None:
    assert status(lua, "{ lastDeath = 0 }", 60, rare="{}") is None


def test_format_timer(lua: LuaRuntime) -> None:
    fmt = lua.eval("ns.FormatTimer")
    assert [fmt(s) for s in (30, 600, 3600, 4980)] == ["<1m", "10m", "1h 00m", "1h 23m"]
