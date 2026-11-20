"""Validate a rare-data submission (GitHub issue body) and merge it into the data files:
recorded rares into data/forever_rares.json, kill and loot counts into data/forever_loot.json.

Used by .github/workflows/rare-data.yml:
    python tools/ingest_submission.py --issue 42 --body body.md

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
from typing import Any, TypeGuard

from build_data import recorded_list

ROOT = Path(__file__).resolve().parent.parent
MAX_RARES = 200
MAX_SPAWNS = 50
MAX_TRACKS = 20  # per rare in one submission
MAX_TRACK_POINTS = 300
MAX_STORED_TRACKS = 30  # per rare in the data file; later tracks are dropped, never swapped in
MAX_NAME = 100
MAX_LEVEL = 100
MAX_COORD = 20000.0
MAX_NPC_ID = 10_000_000
MERGE_DISTANCE = 25.0  # yards; spawn points closer than this are the same point
# Loot statistics: per-submission limits keep one report from swamping the shared numbers.
MAX_KILL_ENTRIES = 500
MAX_KILLS_PER_RARE = 200
MAX_LOOT_ITEMS = 60
MAX_DROPS_PER_KILL = 3  # an item's count can be at most this many times the kills
MAX_ITEM_ID = 10_000_000

_FENCE = re.compile(r"```(?:json)?\s*\n(.*?)\n```", re.S)


class SubmissionError(ValueError):
    pass


@dataclass
class Report:
    added: list[str] = field(default_factory=list)
    updated: list[str] = field(default_factory=list)
    unchanged: list[str] = field(default_factory=list)
    dropped_tracks: int = 0

    def markdown(self, issue: int) -> str:
        lines = [f"### Rare data from #{issue}", ""]
        for title, items in (
            ("New rares", self.added),
            ("Updated rares", self.updated),
            ("Already known", self.unchanged),
        ):
            if items:
                lines.append(f"**{title} ({len(items)}):** " + ", ".join(items))
        if self.dropped_tracks:
            lines.append(
                f"**Tracks not stored ({self.dropped_tracks}):** the rare already has "
                f"{MAX_STORED_TRACKS} tracks."
            )
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


def validate(document: Any, allow_empty: bool = False) -> list[dict[str, Any]]:
    """Normalized rares from a submission; raises SubmissionError on any problem."""
    try:
        rares = recorded_list(document)
    except ValueError as exc:
        raise SubmissionError(str(exc)) from exc
    if not rares and not allow_empty:
        raise SubmissionError("The submission contains no rares.")
    if len(rares) > MAX_RARES:
        raise SubmissionError(f"Too many rares in one submission (max {MAX_RARES}).")
    out = []
    seen_ids: set[int] = set()
    for index, rec in enumerate(rares, 1):
        where = f"Rare #{index}"
        if not isinstance(rec, dict):
            raise SubmissionError(f"{where} is not an object.")
        npc_id = rec.get("id")
        if isinstance(npc_id, bool) or not isinstance(npc_id, int) or not 0 < npc_id < MAX_NPC_ID:
            raise SubmissionError(f"{where} has an invalid id.")
        # Repeating a rare would multiply the per-rare limits (tracks, spawns).
        if npc_id in seen_ids:
            raise SubmissionError(f"{where} ({npc_id}) appears more than once.")
        seen_ids.add(npc_id)
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
                "tracks": _validate_tracks(rec.get("tracks", []), f"{where} ({npc_id})"),
            }
        )
    return out


def _validate_tracks(tracks: Any, where: str) -> list[list[float]]:
    """Patrol tracks: [[map, x1, y1, x2, y2, ...], ...] with at least two points each."""
    if not isinstance(tracks, list) or len(tracks) > MAX_TRACKS:
        raise SubmissionError(f"{where} has invalid tracks.")
    clean = []
    for track in tracks:
        if not isinstance(track, list) or len(track) < 5 or len(track) % 2 == 0:
            raise SubmissionError(f"{where} has a malformed track.")
        if len(track) > 1 + 2 * MAX_TRACK_POINTS:
            raise SubmissionError(f"{where} has a track with too many points.")
        instance = track[0]
        if isinstance(instance, bool) or not isinstance(instance, int) or instance < 0:
            raise SubmissionError(f"{where} has a track with an invalid map id.")
        coords = [round(_number(v, f"{where} track point", MAX_COORD), 2) for v in track[1:]]
        clean.append([instance, *coords])
    return clean


def _positive_int(value: Any, limit: int) -> TypeGuard[int]:
    return not isinstance(value, bool) and isinstance(value, int) and 0 < value <= limit


def validate_kills(document: Any) -> list[dict[str, Any]]:
    """Loot statistics: [{"id", "kills", "loot": {"itemID": count}}, ...] (may be absent)."""
    entries = document.get("kills", []) if isinstance(document, dict) else []
    if not isinstance(entries, list) or len(entries) > MAX_KILL_ENTRIES:
        raise SubmissionError("The loot data is invalid.")
    out = []
    seen: set[int] = set()
    for index, entry in enumerate(entries, 1):
        where = f"Loot entry #{index}"
        if not isinstance(entry, dict):
            raise SubmissionError(f"{where} is not an object.")
        npc_id, kills, loot = entry.get("id"), entry.get("kills"), entry.get("loot")
        if not _positive_int(npc_id, MAX_NPC_ID - 1):
            raise SubmissionError(f"{where} has an invalid id.")
        if npc_id in seen:
            raise SubmissionError(f"{where} ({npc_id}) appears more than once.")
        seen.add(npc_id)
        if not _positive_int(kills, MAX_KILLS_PER_RARE):
            raise SubmissionError(f"{where} ({npc_id}) has an invalid number of kills.")
        if not isinstance(loot, dict) or len(loot) > MAX_LOOT_ITEMS:
            raise SubmissionError(f"{where} ({npc_id}) has invalid loot.")
        clean: dict[str, int] = {}
        for item, count in loot.items():
            if not item.isdigit() or not 0 < int(item) < MAX_ITEM_ID:
                raise SubmissionError(f"{where} ({npc_id}) has an invalid item id.")
            if not _positive_int(count, kills * MAX_DROPS_PER_KILL):
                raise SubmissionError(f"{where} ({npc_id}) has an invalid count for item {item}.")
            clean[str(int(item))] = count
        out.append({"id": npc_id, "kills": kills, "loot": clean})
    return out


def validate_submission(document: Any) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """(rares, kills) of a submission; at least one of them must have content."""
    rares = validate(document, allow_empty=True)
    kills = validate_kills(document)
    if not rares and not kills:
        raise SubmissionError("The submission contains no rares and no loot data.")
    return rares, kills


@dataclass
class LootReport:
    kills: int = 0
    rares: int = 0
    already_counted: int = 0

    def markdown(self) -> str:
        if not self.rares and not self.already_counted:
            return ""
        line = f"**Loot data:** {self.kills} kills of {self.rares} rares"
        if self.already_counted:
            line += f" ({self.already_counted} already counted from this issue)"
        return line + "\n"


def merge_loot(stats: dict[str, Any], incoming: list[dict[str, Any]], issue: int) -> LootReport:
    """Add kills and drops to the shared totals (in place). Each issue is counted once per
    rare, so re-running the workflow for the same issue changes nothing."""
    report = LootReport()
    for entry in incoming:
        current = stats.setdefault(str(entry["id"]), {"kills": 0, "loot": {}, "reports": []})
        if issue in current["reports"]:
            report.already_counted += 1
            continue
        current["kills"] += entry["kills"]
        for item, count in entry["loot"].items():
            current["loot"][item] = current["loot"].get(item, 0) + count
        current["reports"].append(issue)
        report.kills += entry["kills"]
        report.rares += 1
    return report


def dump_loot(stats: dict[str, Any]) -> str:
    """One rare per line, sorted by id, for readable pull request diffs."""
    lines = [
        f"  {json.dumps(key)}:{json.dumps(stats[key], separators=(',', ':'), sort_keys=True)}"
        for key in sorted(stats, key=int)
    ]
    return "{\n" + ",\n".join(lines) + "\n}\n"


def _near(a: list[Any], b: list[Any]) -> bool:
    return a[0] == b[0] and math.hypot(a[1] - b[1], a[2] - b[2]) < MERGE_DISTANCE


def _add_tracks(stored: list[dict[str, Any]], tracks: list[list[float]], issue: int) -> int:
    """Store new tracks with the issue that reported them; returns how many were dropped.
    Once a rare is full, new tracks are dropped: existing data is never displaced, so one
    submission cannot push out tracks that others reported."""
    dropped = 0
    known = [t["points"] for t in stored]
    for track in tracks:
        if track in known:
            continue
        if len(stored) >= MAX_STORED_TRACKS:
            dropped += 1
            continue
        stored.append({"issue": issue, "points": track})
        known.append(track)
    return dropped


def merge(existing: list[dict[str, Any]], incoming: list[dict[str, Any]], issue: int) -> Report:
    """Merge incoming rares into existing (in place). Spawn points are unioned, a missing
    level is filled in, tracks are added with their issue, and the issue number is recorded
    once per rare as a report."""
    by_id = {rec["id"]: rec for rec in existing}
    report = Report()
    for rec in incoming:
        label = f"{rec['name']} ({rec['id']})"
        current = by_id.get(rec["id"])
        if current is None:
            new = {**rec, "tracks": [], "reports": [issue]}
            report.dropped_tracks += _add_tracks(new["tracks"], rec["tracks"], issue)
            existing.append(new)
            by_id[rec["id"]] = new
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
        stored = current.setdefault("tracks", [])
        before = len(stored)
        report.dropped_tracks += _add_tracks(stored, rec["tracks"], issue)
        changed = changed or len(stored) > before
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
    parser.add_argument("--loot", type=Path, default=ROOT / "data" / "forever_loot.json")
    parser.add_argument("--report", type=Path, help="write the Markdown report here")
    args = parser.parse_args()

    def emit(text: str) -> None:
        if args.report:
            args.report.write_text(text, encoding="utf-8")
        else:
            sys.stdout.write(text)

    try:
        rares, kills = validate_submission(extract_json(args.body.read_text(encoding="utf-8")))
    except SubmissionError as exc:
        emit(
            f"### Could not process this submission\n\n{exc}\n\n"
            "Please copy the data again from the RareCodex window in game "
            "(`/rc share`) and open a new issue with it.\n"
        )
        return 1
    existing = recorded_list(json.loads(args.data.read_text(encoding="utf-8")))
    report = merge(existing, rares, args.issue)
    args.data.write_text(dump(existing), encoding="utf-8", newline="\n")
    stats = json.loads(args.loot.read_text(encoding="utf-8")) if args.loot.is_file() else {}
    loot_report = merge_loot(stats, kills, args.issue)
    args.loot.write_text(dump_loot(stats), encoding="utf-8", newline="\n")
    emit(report.markdown(args.issue) + loot_report.markdown())
    return 0


if __name__ == "__main__":
    sys.exit(main())
