import json
from pathlib import Path

import pytest

from ingest_submission import SubmissionError, dump, extract_json, main, merge, validate

RARE = {"id": 900001, "name": "Eck'alom", "level": 27, "elite": False, "spawns": [[1, 10.0, 20.0]]}


def submission(*rares: dict) -> dict:
    return {"addon": "0.2.0", "game": "1.60.1 70959", "locale": "esES", "rares": list(rares)}


def test_extract_json_from_issue_form_body() -> None:
    body = (
        "### Data\n\n```json\n"
        + json.dumps(submission(RARE))
        + "\n```\n\n### Notes\n\n_No response_"
    )
    assert extract_json(body)["rares"][0]["id"] == 900001


def test_extract_json_without_fence() -> None:
    assert extract_json(json.dumps([RARE]))[0]["name"] == "Eck'alom"


def test_invalid_json_is_reported() -> None:
    with pytest.raises(SubmissionError, match="not valid JSON"):
        extract_json("```json\n{oops\n```")


@pytest.mark.parametrize(
    ("change", "message"),
    [
        ({"id": -1}, "invalid id"),
        ({"id": True}, "invalid id"),
        ({"name": ""}, "invalid name"),
        ({"name": "x" * 101}, "invalid name"),
        ({"name": "Line\nbreak"}, "invalid characters"),
        ({"name": "|cffff0000Red|r"}, "invalid characters"),
        ({"level": 500}, "invalid level"),
        ({"spawns": [[1, 10.0]]}, "malformed spawn"),
        ({"spawns": [[1, 1e9, 0]]}, "out of range"),
        ({"spawns": [[1, "10", 0]]}, "must be a number"),
        ({"spawns": [[-1, 0, 0]]}, "invalid map id"),
    ],
)
def test_validation_rejects_bad_rares(change: dict, message: str) -> None:
    with pytest.raises(SubmissionError, match=message):
        validate(submission({**RARE, **change}))


def test_validation_rejects_empty_submission() -> None:
    with pytest.raises(SubmissionError, match="no rares"):
        validate(submission())


def test_merge_adds_then_confirms_and_unions_spawns() -> None:
    data: list[dict] = []
    first = merge(data, validate(submission(RARE)), issue=1)
    assert first.added == ["Eck'alom (900001)"]
    assert data[0]["reports"] == [1]

    second_report = {**RARE, "level": None, "spawns": [[1, 12.0, 20.0], [1, 300.0, 20.0]]}
    second = merge(data, validate(submission(second_report)), issue=2)
    assert second.updated == ["Eck'alom (900001)"]
    assert data[0]["reports"] == [1, 2]
    assert data[0]["spawns"] == [[1, 10.0, 20.0], [1, 300.0, 20.0]]  # 2 yards away merged
    assert data[0]["level"] == 27  # a missing level never erases a known one


def test_merge_is_idempotent_per_issue() -> None:
    data: list[dict] = []
    merge(data, validate(submission(RARE)), issue=1)
    again = merge(data, validate(submission(RARE)), issue=1)
    assert again.unchanged == ["Eck'alom (900001)"]
    assert data[0]["reports"] == [1]


def test_main_writes_data_and_report(tmp_path: Path) -> None:
    data = tmp_path / "forever_rares.json"
    data.write_text("[\n]\n", encoding="utf-8")
    body = tmp_path / "body.md"
    body.write_text("```json\n" + json.dumps(submission(RARE)) + "\n```", encoding="utf-8")
    report = tmp_path / "report.md"
    import sys

    argv = sys.argv
    sys.argv = [
        "ingest",
        "--issue",
        "7",
        "--body",
        str(body),
        "--data",
        str(data),
        "--report",
        str(report),
    ]
    try:
        assert main() == 0
    finally:
        sys.argv = argv
    assert json.loads(data.read_text(encoding="utf-8"))[0]["reports"] == [7]
    assert "New rares (1)" in report.read_text(encoding="utf-8")
    assert data.read_text(encoding="utf-8") == dump(json.loads(data.read_text(encoding="utf-8")))


TRACK = [1, 10.0, 20.0, 15.0, 20.0, 20.0, 20.0]


def test_tracks_are_validated_and_merged_without_duplicates() -> None:
    data: list[dict] = []
    merge(data, validate(submission({**RARE, "tracks": [TRACK]})), issue=1)
    other = [1, 50.0, 50.0, 60.0, 50.0]
    merge(data, validate(submission({**RARE, "tracks": [TRACK, other]})), issue=2)
    assert data[0]["tracks"] == [
        {"issue": 1, "points": TRACK},
        {"issue": 2, "points": other},
    ]


def test_repeated_rare_in_one_submission_is_rejected() -> None:
    with pytest.raises(SubmissionError, match="more than once"):
        validate(submission(RARE, RARE))


def test_full_rare_keeps_existing_tracks_and_drops_new_ones() -> None:
    from ingest_submission import MAX_STORED_TRACKS

    data: list[dict] = []
    first = [[1, float(i), 0.0, float(i) + 1, 0.0] for i in range(MAX_STORED_TRACKS)]
    for start in range(0, MAX_STORED_TRACKS, 20):  # one submission holds at most 20 tracks
        merge(data, validate(submission({**RARE, "tracks": first[start : start + 20]})), issue=1)
    longest_possible = [1, *([5000.0] * 600)]
    report = merge(data, validate(submission({**RARE, "tracks": [longest_possible]})), issue=2)
    assert [t["points"] for t in data[0]["tracks"]] == first
    assert report.dropped_tracks == 1
    assert "Tracks not stored (1)" in report.markdown(2)


def test_generator_reads_stored_tracks_with_provenance(tmp_path: Path) -> None:
    from build_data import load_recorded

    data: list[dict] = []
    track = [1, *[v for i in range(10) for v in (5.0 * i, 0.0)]]
    merge(data, validate(submission({**RARE, "tracks": [track]})), issue=3)
    path = tmp_path / "forever_rares.json"
    path.write_text(dump(data), encoding="utf-8")
    spawn = load_recorded(path)[RARE["id"]]["spawns"][0]
    assert len(spawn["path"]) == 10  # type: ignore[index]


@pytest.mark.parametrize(
    ("tracks", "message"),
    [
        ("nope", "invalid tracks"),
        ([[1, 10.0, 20.0]], "malformed track"),  # a single point
        ([[1, 10.0, 20.0, 30.0]], "malformed track"),  # odd coordinate count
        ([[1, *([1.0] * 602)]], "too many points"),
        ([[-1, 1.0, 1.0, 2.0, 2.0]], "invalid map id"),
        ([[1, 1.0, 1e9, 2.0, 2.0]], "out of range"),
    ],
)
def test_bad_tracks_are_rejected(tracks: object, message: str) -> None:
    with pytest.raises(SubmissionError, match=message):
        validate(submission({**RARE, "tracks": tracks}))


# --- loot statistics -----------------------------------------------------------------
KILLS = {"id": 3736, "kills": 3, "loot": {"2592": 1, "4606": 2}}


def test_submission_with_only_loot_is_valid() -> None:
    from ingest_submission import validate_submission

    rares, kills = validate_submission({"rares": [], "kills": [KILLS]})
    assert rares == [] and kills == [KILLS]


def test_empty_submission_is_rejected() -> None:
    from ingest_submission import validate_submission

    with pytest.raises(SubmissionError, match="no rares and no loot"):
        validate_submission({"rares": [], "kills": []})


@pytest.mark.parametrize(
    ("change", "message"),
    [
        ({"id": 0}, "invalid id"),
        ({"kills": 0}, "invalid number of kills"),
        ({"kills": 201}, "invalid number of kills"),
        ({"loot": []}, "invalid loot"),
        ({"loot": {"abc": 1}}, "invalid item id"),
        ({"loot": {"2592": 10}}, "invalid count"),  # 10 > 3 kills * 3
        ({"loot": {"2592": 0}}, "invalid count"),
    ],
)
def test_bad_loot_is_rejected(change: dict, message: str) -> None:
    from ingest_submission import validate_kills

    with pytest.raises(SubmissionError, match=message):
        validate_kills({"kills": [{**KILLS, **change}]})


def test_repeated_rare_in_loot_is_rejected() -> None:
    from ingest_submission import validate_kills

    with pytest.raises(SubmissionError, match="more than once"):
        validate_kills({"kills": [KILLS, KILLS]})


def test_loot_accumulates_across_issues_and_counts_each_issue_once() -> None:
    from ingest_submission import dump_loot, merge_loot

    stats: dict = {}
    assert merge_loot(stats, [KILLS], issue=1).kills == 3
    merge_loot(stats, [{"id": 3736, "kills": 2, "loot": {"2592": 1}}], issue=2)
    again = merge_loot(stats, [KILLS], issue=1)
    assert again.kills == 0 and again.already_counted == 1
    assert stats["3736"] == {"kills": 5, "loot": {"2592": 2, "4606": 2}, "reports": [1, 2]}
    assert json.loads(dump_loot(stats)) == stats
