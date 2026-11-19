"""Validate a rare-data submission (GitHub issue body) and merge it into the data file.

Used by .github/workflows/rare-data.yml:
    python tools/ingest_submission.py --issue 42 --body body.md [--data data/forever_rares.json]

Writes a Markdown report to --report (default: stdout) and exits with status 1 when the
submission is invalid, so the workflow can comment the errors on the issue instead of
opening a pull request. Merging is idempotent: re-running for the same issue changes nothing.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from build_data import recorded_list

ROOT = Path(__file__).resolve().parent.parent
MAX_RARES = 200
MAX_SPAWNS = 50
MAX_NAME = 100
MAX_LEVEL = 100
MAX_COORD = 20000.0
MAX_NPC_ID = 10_000_000
MERGE_DISTANCE = 25.0  # yards; spawn points closer than this are the same point

_FENCE = re.compile(r"```(?:json)?\s*\n(.*?)\n```", re.S)


class SubmissionError(ValueError):
    pass


@dataclass
class Report:
    added: list[str] = field(default_factory=list)
    updated: list[str] = field(default_factory=list)
    unchanged: list[str] = field(default_factory=list)

    def markdown(self, issue: int) -> str:
        lines = [f"### Rare data from #{issue}", ""]
        for title, items in (
            ("New rares", self.added),
            ("Updated rares", self.updated),
            ("Already known", self.unchanged),
        ):
            if items:
                lines.append(f"**{title} ({len(items)}):** " + ", ".join(items))
        return "\n".join(lines) + "\n"


def extract_json(body: str) -> Any:
    """The submitted JSON: the first fenced block (issue forms render the field as ```json),
    or the whole body when there is no fence."""
    match = _FENCE.search(body)
    text = match.group(1) if match else body
    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        raise SubmissionError(
            f"The data is not valid JSON ({exc.msg}, line {exc.lineno})."
        ) from exc


def _number(value: Any, what: str, limit: float) -> float:
    if isinstance(value, bool) or not isinstance(value, int | float) or not math.isfinite(value):
        raise SubmissionError(f"{what} must be a number.")
    if abs(value) > limit:
        raise SubmissionError(f"{what} is out of range.")
    return float(value)


def validate(document: Any) -> list[dict[str, Any]]:
    """Normalized rares from a submission; raises SubmissionError on any problem."""
    try:
        rares = recorded_list(document)
    except ValueError as exc:
        raise SubmissionError(str(exc)) from exc
    if not rares:
        raise SubmissionError("The submission contains no rares.")
    if len(rares) > MAX_RARES:
        raise SubmissionError(f"Too many rares in one submission (max {MAX_RARES}).")
    out = []
    for index, rec in enumerate(rares, 1):
        where = f"Rare #{index}"
        if not isinstance(rec, dict):
            raise SubmissionError(f"{where} is not an object.")
        npc_id = rec.get("id")
        if isinstance(npc_id, bool) or not isinstance(npc_id, int) or not 0 < npc_id < MAX_NPC_ID:
            raise SubmissionError(f"{where} has an invalid id.")
        name = rec.get("name")
        if not isinstance(name, str) or not name.strip() or len(name) > MAX_NAME:
            raise SubmissionError(f"{where} ({npc_id}) has an invalid name.")
        # "|" starts WoW escape sequences (colors, links, textures) in game text.
        if not name.isprintable() or "|" in name:
            raise SubmissionError(f"{where} ({npc_id}) has invalid characters in its name.")
        level = rec.get("level")
        if level is not None and (
            isinstance(level, bool) or not isinstance(level, int) or not 0 < level <= MAX_LEVEL
        ):
            raise SubmissionError(f"{where} ({npc_id}) has an invalid level.")
        spawns = rec.get("spawns")
        if not isinstance(spawns, list) or len(spawns) > MAX_SPAWNS:
            raise SubmissionError(f"{where} ({npc_id}) has invalid spawns.")
        clean_spawns = []
        for spawn in spawns:
            if not isinstance(spawn, list) or len(spawn) != 3:
                raise SubmissionError(f"{where} ({npc_id}) has a malformed spawn point.")
            instance = spawn[0]
            if isinstance(instance, bool) or not isinstance(instance, int) or instance < 0:
                raise SubmissionError(f"{where} ({npc_id}) has an invalid map id.")
            x = _number(spawn[1], f"{where} ({npc_id}) x", MAX_COORD)
            y = _number(spawn[2], f"{where} ({npc_id}) y", MAX_COORD)
            clean_spawns.append([instance, round(x, 2), round(y, 2)])
        out.append(
            {
                "id": npc_id,
                "name": name.strip(),
                "level": level,
                "elite": bool(rec.get("elite")),
                "spawns": clean_spawns,
            }
        )
    return out


def _near(a: list[Any], b: list[Any]) -> bool:
    return a[0] == b[0] and math.hypot(a[1] - b[1], a[2] - b[2]) < MERGE_DISTANCE


def merge(existing: list[dict[str, Any]], incoming: list[dict[str, Any]], issue: int) -> Report:
    """Merge incoming rares into existing (in place). Spawn points are unioned, a missing
    level is filled in, and the issue number is recorded once per rare as a report."""
    by_id = {rec["id"]: rec for rec in existing}
    report = Report()
    for rec in incoming:
        label = f"{rec['name']} ({rec['id']})"
        current = by_id.get(rec["id"])
        if current is None:
            existing.append({**rec, "reports": [issue]})
            by_id[rec["id"]] = existing[-1]
            report.added.append(label)
            continue
        changed = False
        for spawn in rec["spawns"]:
            if not any(_near(spawn, s) for s in current["spawns"]):
                current["spawns"].append(spawn)
                changed = True
        if current.get("level") is None and rec["level"] is not None:
            current["level"] = rec["level"]
            changed = True
        reports = current.setdefault("reports", [])
        if issue not in reports:
            reports.append(issue)
            changed = True
        (report.updated if changed else report.unchanged).append(label)
    existing.sort(key=lambda r: r["id"])
    return report


def dump(rares: list[dict[str, Any]]) -> str:
    """One rare per line keeps diffs of the data file readable in pull requests."""
    lines = [json.dumps(r, ensure_ascii=False, separators=(",", ":")) for r in rares]
    return "[\n" + ",\n".join("  " + line for line in lines) + "\n]\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--issue", type=int, required=True)
    parser.add_argument("--body", type=Path, required=True, help="file with the issue body")
    parser.add_argument("--data", type=Path, default=ROOT / "data" / "forever_rares.json")
    parser.add_argument("--report", type=Path, help="write the Markdown report here")
    args = parser.parse_args()

    def emit(text: str) -> None:
        if args.report:
            args.report.write_text(text, encoding="utf-8")
        else:
            sys.stdout.write(text)

    try:
        incoming = validate(extract_json(args.body.read_text(encoding="utf-8")))
    except SubmissionError as exc:
        emit(
            f"### Could not process this submission\n\n{exc}\n\n"
            "Please copy the data again from the RareCodex window in game "
            "(`/rc share`) and open a new issue with it.\n"
        )
        return 1
    existing = recorded_list(json.loads(args.data.read_text(encoding="utf-8")))
    report = merge(existing, incoming, args.issue)
    args.data.write_text(dump(existing), encoding="utf-8", newline="\n")
    emit(report.markdown(args.issue))
    return 0


if __name__ == "__main__":
    sys.exit(main())
