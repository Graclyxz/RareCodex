"""Runs the addon's pure geometry helpers in Lua, outside the game client."""

from collections.abc import Sequence
from pathlib import Path

import pytest
from lupa import LuaRuntime

OVERLAY = Path(__file__).resolve().parent.parent / "RareCodex" / "Map" / "Overlay.lua"

# WoW runs Lua 5.1; lupa ships 5.4, which lacks these.
COMPAT = """
math.atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
"""


@pytest.fixture(scope="module")
def overlay():  # noqa: ANN201 - lupa table
    lua = LuaRuntime()
    lua.execute(COMPAT)
    ns = lua.table()
    chunk = lua.eval("function(src) return load(src, 'Overlay.lua') end")(
        OVERLAY.read_text(encoding="utf-8")
    )
    chunk("RareCodex", ns)
    return lua, ns.Overlay


def as_list(table) -> list[float]:  # noqa: ANN001
    return [table[i] for i in range(1, len(table) + 1)]


def to_lua(lua, values: Sequence[float]):  # noqa: ANN001, ANN201
    return lua.table_from(values)


def test_smooth_open_path_keeps_pairs_and_endpoints(overlay) -> None:  # noqa: ANN001
    lua, mod = overlay
    pts = [0, 0, 10, 0, 10, 10, 20, 10]
    out = as_list(mod._Smooth(to_lua(lua, pts), False))
    assert len(out) % 2 == 0
    assert out[:2] == [0, 0]
    assert out[-2:] == [20, 10]
    assert len(out) > len(pts)


def test_smooth_closed_path_keeps_pairs(overlay) -> None:  # noqa: ANN001
    lua, mod = overlay
    out = as_list(mod._Smooth(to_lua(lua, [0, 0, 10, 0, 10, 10, 0, 10]), True))
    assert len(out) == 4 * 2 * 2 * 2  # 4 corners, doubled per pass, 2 passes, x/y


def test_simplify_drops_close_points_but_keeps_both_ends(overlay) -> None:  # noqa: ANN001
    lua, mod = overlay
    pts = [0, 0, 1, 0, 2, 0, 10, 0, 11, 0, 12, 0.5]
    out = as_list(mod._Simplify(to_lua(lua, pts), False, 5))
    # (10, 0) is kept, then the true end (12, 0.5) is too close to it and replaces it,
    # so the route still ends where it should without a tiny final segment.
    assert out == [0, 0, 12, 0.5]
    longer = [0, 0, 1, 0, 6, 0, 12, 0, 13, 0.5]
    assert as_list(mod._Simplify(to_lua(lua, longer), False, 5)) == [0, 0, 6, 0, 13, 0.5]


def test_simplify_keeps_tiny_closed_shapes(overlay) -> None:  # noqa: ANN001
    lua, mod = overlay
    pts = [0, 0, 1, 0, 1, 1, 0, 1]
    assert as_list(mod._Simplify(to_lua(lua, pts), True, 5)) == pts


def test_convex_hull_drops_inner_points(overlay) -> None:  # noqa: ANN001
    lua, mod = overlay
    square_with_center = [0, 0, 10, 0, 10, 10, 0, 10, 5, 5, 5, 0]
    hull = as_list(mod._ConvexHull(to_lua(lua, square_with_center)))
    corners = {(hull[i], hull[i + 1]) for i in range(0, len(hull), 2)}
    assert corners == {(0, 0), (10, 0), (10, 10), (0, 10)}


def test_spawn_area_pads_two_points_into_a_capsule(overlay) -> None:  # noqa: ANN001
    lua, mod = overlay
    area = as_list(mod._SpawnArea(to_lua(lua, [0, 0, 100, 0]), 10))
    xs, ys = area[0::2], area[1::2]
    assert len(area) % 2 == 0 and len(xs) > 4
    assert min(xs) == pytest.approx(-10) and max(xs) == pytest.approx(110)
    assert min(ys) == pytest.approx(-10, abs=0.5) and max(ys) == pytest.approx(10, abs=0.5)


def test_cap_points_marks_ends_and_sharp_turns_only(overlay) -> None:  # noqa: ANN001
    lua, mod = overlay
    # straight, straight, then a U-turn: ends + the turn-back point need caps
    caps = mod._CapPoints(to_lua(lua, [0, 0, 10, 0, 20, 0, 10, 0.1]), False)
    points = [(caps[i][1], caps[i][2]) for i in range(1, len(caps) + 1)]
    assert points == [(0, 0), (20, 0), (10, 0.1)]
