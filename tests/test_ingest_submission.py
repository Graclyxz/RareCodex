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
