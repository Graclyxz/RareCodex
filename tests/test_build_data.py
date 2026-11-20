import json

import pytest
from lupa import LuaRuntime

from build_data import (
    LootItem,
    WorldDrop,
    load_recorded,
    lua_chance,
    merge_recorded,
    merge_world_drops,
    resolve_chances,
    to_lua,
)


def loot_row(item: int, chance: float, group: int = 0) -> dict[str, int | float]:
    return {"item": item, "ChanceOrQuestChance": chance, "groupid": group, "mincountOrRef": 1}


def chances(rows: list[dict[str, int | float]]) -> dict[int, float]:
    return {int(r["item"]): c for r, c in resolve_chances(rows)}  # type: ignore[arg-type]


def test_ungrouped_rows_keep_their_chance_and_quest_sign_is_dropped() -> None:
    assert chances([loot_row(1, 23.5), loot_row(2, -40)]) == {1: 23.5, 2: 40}


def test_group_rows_with_zero_chance_share_the_remainder() -> None:
    result = chances([loot_row(1, 20, group=1), loot_row(2, 0, group=1), loot_row(3, 0, group=1)])
    assert result == {1: 20, 2: pytest.approx(40), 3: pytest.approx(40)}


def test_world_drops_of_same_quality_merge_as_independent_rolls() -> None:
    merged = merge_world_drops(
        [WorldDrop(1, 50, 6), WorldDrop(4, 0.01, 2, [LootItem(867, 0.005)]), WorldDrop(1, 50, 2)]
    )
    assert [d.quality for d in merged] == [4, 1]
    assert merged[1].chance == pytest.approx(75)  # 1 - 0.5 * 0.5
    assert merged[1].count == 8
    assert merged[0].items == [LootItem(867, 0.005)]


def test_lua_chance_keeps_tiny_values_visible() -> None:
    assert lua_chance(0.0016666) == "0.00167"
    assert lua_chance(23.0769) == "23.1"


def test_generated_lua_loads_with_expected_shape() -> None:
    rare = {
        "name": 'Lady "Szallah"',
        "level": (46, 46),
        "elite": True,
        "display": 11262,
        "respawn": (18000, 28800),
        "gold": (76, 105),
        "flee": 15,
        "spells": [6728, 9532],
        "spawns": [
            {
                "map": 1,
                "x": -5498.69,
                "y": 3481.84,
                "wander": 0.0,
                "path": [(-5498.69, 3481.84), (-5480.0, 3490.5)],
            },
        ],
        "loot": [LootItem(9247, 40, quest=True), LootItem(7973, 30.49)],
        "world": [WorldDrop(4, 0.01, 2, [LootItem(867, 0.005)]), WorldDrop(2, 90, 282)],
    }
    lua = LuaRuntime(unpack_returned_tuples=True)
    data = lua.execute("local D = {}\n" + to_lua(5343, rare) + "\nreturn D")[5343]
    assert data["name"] == 'Lady "Szallah"'
    assert data["elite"] is True and data["flee"] == 15
    assert data["loot"][1][3] is True
    assert data["loot"][2][2] == pytest.approx(30.5)  # kept to 3 significant digits
    spawn = data["spawns"][1]
    assert (spawn[1], spawn[2], spawn[3]) == (1, pytest.approx(-5498.69), pytest.approx(3481.84))
    assert len(spawn["path"]) == 4
    assert data["world"][1]["items"][1][1] == 867
    assert data["world"][2]["items"] is None


RECORDED_JSON = """[
  {"id":900001,"name":"Eck'alom","level":27,"elite":false,"spawns":[[1,2230.5,222.25]]},
  {"id":5352,"name":"Old Grizzlegut","level":null,"elite":false,"spawns":[[1,1,2]]},
  {"id":900002,"name":"No spawns","level":null,"elite":true,"spawns":[]}
]"""


def test_recorded_rares_merge_only_when_new_and_placeable(tmp_path) -> None:  # noqa: ANN001
    path = tmp_path / "forever_rares.json"
    path.write_text(RECORDED_JSON, encoding="utf-8")
    recorded = load_recorded(path)
    rares: dict[int, dict[str, object]] = {5352: {"name": "Old Grizzlegut"}}
    promoted, skipped = merge_recorded(rares, recorded)
    assert promoted == []
    assert skipped == [5352, 900002]
    assert rares[900001]["level"] == (27, 27)
    assert rares[900001]["unknown"] is True


def test_missing_recorded_file_is_empty(tmp_path) -> None:  # noqa: ANN001
    assert load_recorded(tmp_path / "nope.json") == {}


def test_recorded_rare_serializes_without_optional_fields(tmp_path) -> None:  # noqa: ANN001
    path = tmp_path / "forever_rares.json"
    path.write_text(RECORDED_JSON, encoding="utf-8")
    rare = load_recorded(path)[900002]
    rare["spawns"] = [{"map": 1, "x": 1.0, "y": 2.0, "wander": 0.0, "path": []}]
    lua = LuaRuntime(unpack_returned_tuples=True)
    data = lua.execute("local D = {}\n" + to_lua(900002, rare) + "\nreturn D")[900002]
    assert data["unknown"] is True and data["elite"] is True
    assert data["level"] is None and data["respawn"] is None and data["display"] is None


@pytest.mark.parametrize(
    "name",
    [
        'Evil"\nos.exit() --',  # newline + quote: tries to end the string and inject code
        "back\\slash\\",
        "tab\tbell\a\x7f",
        "Ünïcödé Eck'alom",
    ],
)
def test_lua_str_round_trips_any_name(name: str) -> None:
    from build_data import lua_str

    literal = lua_str(name)
    assert "\n" not in literal
    assert LuaRuntime().execute(f"return {literal}") == name


# --- recorded patrol tracks and promotion -----------------------------------------
def straight(map_id: int, x0: float, y0: float, length: float, step: float = 5.0):  # noqa: ANN201
    n = int(length / step) + 1
    return (map_id, [(x0 + i * step, y0) for i in range(n)])


def test_patrol_routes_keep_the_longest_track_of_each_route() -> None:
    from build_data import patrol_routes

    short_same_route = straight(1, 0, 0, 40)
    long_same_route = straight(1, 0, 10, 120)  # 10 yards away: same route
    other_route = straight(1, 1000, 1000, 50)
    standing = straight(1, 500, 500, 5)  # barely moved: not a patrol
    routes = patrol_routes([short_same_route, long_same_route, other_route, standing])
    assert sorted(routes) == sorted([long_same_route, other_route])


def test_recorded_spawns_turn_routes_into_paths_and_keep_other_sightings() -> None:
    from build_data import recorded_spawns

    route = straight(1, 0, 0, 100)
    spawns = recorded_spawns([[1, 50, 3], [1, 900, 900]], [route])
    assert [(s["x"], s["y"], len(s["path"])) for s in spawns] == [(0, 0, 21), (900, 900, 0)]


def test_attach_routes_to_nearest_database_spawn_or_add_new_spawn() -> None:
    from build_data import attach_routes

    rare = {"spawns": [{"map": 1, "x": 10.0, "y": 0.0, "wander": 5.0, "path": []}]}
    near, far = straight(1, 0, 0, 100), straight(1, 5000, 5000, 100)
    attach_routes(rare, [near, far])
    spawns = rare["spawns"]
    assert spawns[0]["path"] == near[1] and spawns[0]["wander"] == 0.0
    assert spawns[1]["x"] == 5000 and spawns[1]["path"] == far[1]


def test_merge_recorded_promotes_database_creatures_with_player_routes(tmp_path) -> None:  # noqa: ANN001
    path = tmp_path / "forever_rares.json"
    track = [1, *[v for i in range(30) for v in (1000.0 + 5 * i, 50.0)]]
    path.write_text(
        json.dumps(
            [
                {
                    "id": 3736,
                    "name": "Mordenthal",
                    "level": 23,
                    "elite": True,
                    "spawns": [[1, 1000, 50]],
                    "tracks": [track],
                },
                {
                    "id": 900001,
                    "name": "New",
                    "level": None,
                    "elite": False,
                    "spawns": [[1, 1, 2]],
                    "tracks": [],
                },
            ]
        ),
        encoding="utf-8",
    )
    recorded = load_recorded(path)

    def promote(npc_id: int, elite: bool) -> dict | None:
        if npc_id != 3736:
            return None
        spawn = {"map": 1, "x": 990.0, "y": 50.0, "wander": 0.0, "path": []}
        return {"name": "Darkslayer Mordenthal", "elite": elite, "loot": [1], "spawns": [spawn]}

    rares: dict[int, dict[str, object]] = {}
    promoted, skipped = merge_recorded(rares, recorded, promote)
    assert promoted == [3736] and skipped == []
    assert rares[3736]["elite"] is True and rares[3736]["loot"] == [1]
    assert len(rares[3736]["spawns"][0]["path"]) == 30  # type: ignore[index]
    assert rares[900001]["unknown"] is True
    assert "tracks" not in rares[3736] and "tracks" not in rares[900001]


# --- drop chances measured in WoW Forever -----------------------------------------
def test_lua_item_flags() -> None:
    from build_data import lua_item

    assert lua_item(LootItem(1, 50)) == "{1,50}"
    assert lua_item(LootItem(1, 50, quest=True)) == "{1,50,true}"
    assert lua_item(LootItem(1, 50, observed=True)) == "{1,50,false,true}"
    assert lua_item(LootItem(1, 50, quest=True, observed=True)) == "{1,50,true,true}"


def known_rare() -> dict[str, object]:
    return {"loot": [LootItem(10, 20.0), LootItem(11, 5.0)]}


def test_known_rare_needs_min_kills_before_measured_chances_apply() -> None:
    from build_data import apply_forever_loot

    rares = {1: known_rare()}
    assert apply_forever_loot(rares, {1: (5, {10: 4})}, min_kills=20) == []
    assert rares[1]["loot"][0].chance == 20.0  # type: ignore[index]


def test_measured_chances_replace_estimates_and_add_repeated_new_items() -> None:
    from build_data import apply_forever_loot

    rares = {1: known_rare()}
    stats = {1: (40, {10: 4, 99: 2, 98: 1})}  # 99 seen twice, 98 once (random world drop)
    assert apply_forever_loot(rares, stats, min_kills=20) == [1]
    loot = {i.item: i for i in rares[1]["loot"]}  # type: ignore[attr-defined]
    assert loot[10].chance == 10.0 and loot[10].observed
    assert loot[11].chance == 5.0 and not loot[11].observed  # never seen: keeps the estimate
    assert loot[99].chance == 5.0 and loot[99].observed
    assert 98 not in loot
    assert rares[1]["forever"] == 40


def test_rare_without_loot_table_uses_measurements_from_the_first_kill() -> None:
    from build_data import apply_forever_loot

    rares: dict[int, dict[str, object]] = {2: {"loot": [], "unknown": True}}
    assert apply_forever_loot(rares, {2: (2, {50: 1})}, min_kills=20) == [2]
    assert rares[2]["loot"] == [LootItem(50, 50.0, observed=True)]
    assert rares[2]["forever"] == 2


# --- abilities added by a maintainer -------------------------------------------------
def test_recorded_rares_carry_maintainer_spells_and_promotion_merges_them(tmp_path) -> None:  # noqa: ANN001
    path = tmp_path / "forever_rares.json"
    path.write_text(
        json.dumps(
            [
                {
                    "id": 3736,
                    "name": "M",
                    "level": 23,
                    "elite": False,
                    "spawns": [[1, 0, 0]],
                    "spells": [133, 9532],
                },
                {
                    "id": 900001,
                    "name": "N",
                    "level": None,
                    "elite": False,
                    "spawns": [[1, 1, 2]],
                    "spells": [8435],
                },
            ]
        ),
        encoding="utf-8",
    )

    def promote(npc_id: int, elite: bool) -> dict | None:
        spawn = {"map": 1, "x": 0.0, "y": 0.0, "wander": 0.0, "path": []}
        return (
            {"name": "M", "elite": elite, "spells": [9532], "spawns": [spawn]}
            if npc_id == 3736
            else None
        )

    rares: dict[int, dict[str, object]] = {}
    merge_recorded(rares, load_recorded(path), promote)
    assert rares[3736]["spells"] == [9532, 133]  # database first, no duplicates
    assert rares[900001]["spells"] == [8435]
