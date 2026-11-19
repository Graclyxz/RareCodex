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
    skipped = merge_recorded(rares, recorded)
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
