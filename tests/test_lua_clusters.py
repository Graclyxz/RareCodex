"""Runs the pin clustering of Map/Coords.lua outside the game client."""

from pathlib import Path

from lupa import LuaRuntime

COORDS = Path(__file__).resolve().parent.parent / "RareCodex" / "Map" / "Coords.lua"


def clusters(points: list[tuple[float, float]], radius: float = 0.01) -> list[list[int]]:
    """Clusters of the given pin positions, as lists of indexes (1-based, as in Lua)."""
    lua = LuaRuntime()
    lua.execute("Enum = { UIMapType = { World = 1, Continent = 2, Zone = 3, Micro = 5 } }")
    ns = lua.eval("{ L = {}, On = function() end }")
    load = lua.eval("function(src) return load(src, 'Coords.lua') end")
    load(COORDS.read_text(encoding="utf-8"))("RareCodex", ns)
    groups = lua.table_from(
        [
            lua.table_from({"id": i, "primary": lua.table_from({"x": x, "y": y})})
            for i, (x, y) in enumerate(points, 1)
        ]
    )
    result = ns.Coords.Clusters(groups, radius)
    return [[group.id for group in cluster.groups.values()] for cluster in result.values()]


def test_far_apart_rares_keep_their_own_pin() -> None:
    assert clusters([(0.1, 0.1), (0.5, 0.5), (0.9, 0.1)]) == [[1], [2], [3]]


def test_rares_on_the_same_spot_share_a_pin() -> None:
    assert clusters([(0.3, 0.3), (0.6, 0.6), (0.3, 0.3), (0.305, 0.298)]) == [[1, 3, 4], [2]]


def test_close_on_one_axis_only_is_not_enough() -> None:
    assert clusters([(0.3, 0.3), (0.3, 0.35)]) == [[1], [2]]


def test_radius_per_axis() -> None:
    lua = LuaRuntime()
    lua.execute("Enum = { UIMapType = { World = 1, Continent = 2, Zone = 3, Micro = 5 } }")
    ns = lua.eval("{ L = {}, On = function() end }")
    lua.eval("function(src) return load(src, 'Coords.lua') end")(
        COORDS.read_text(encoding="utf-8")
    )("RareCodex", ns)
    lua.globals().ns = ns
    count = lua.eval(
        "function(rx, ry) return #ns.Coords.Clusters({ { primary = { x = 0.5, y = 0.5 } },"
        " { primary = { x = 0.5, y = 0.52 } } }, rx, ry) end"
    )
    assert count(0.01, 0.03) == 1  # taller radius: same pin
    assert count(0.01, 0.01) == 2


def test_cluster_keeps_the_position_of_its_first_rare() -> None:
    lua = LuaRuntime()
    lua.execute("Enum = { UIMapType = { World = 1, Continent = 2, Zone = 3, Micro = 5 } }")
    ns = lua.eval("{ L = {}, On = function() end }")
    lua.eval("function(src) return load(src, 'Coords.lua') end")(
        COORDS.read_text(encoding="utf-8")
    )("RareCodex", ns)
    lua.globals().ns = ns
    cluster = lua.eval(
        "ns.Coords.Clusters({ { primary = { x = 0.2, y = 0.4 } },"
        " { primary = { x = 0.205, y = 0.4 } } }, 0.01)[1]"
    )
    assert (cluster.x, cluster.y) == (0.2, 0.4)
