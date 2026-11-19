"""Minimal reader for MySQL dump files (``INSERT INTO ... VALUES (...),(...);``).

Avoids requiring a MySQL server: rows are parsed straight from the dump text.
"""

from __future__ import annotations

import re
from collections.abc import Iterator
from pathlib import Path

Value = int | float | str | None
Row = dict[str, Value]

_CREATE_RE = re.compile(r"CREATE TABLE (?:IF NOT EXISTS )?`(\w+)` \((.*?)\n\)", re.S)
_COLUMN_RE = re.compile(r"^\s*`(\w+)`", re.M)
_INSERT_RE = re.compile(r"INSERT (?:IGNORE )?INTO `(\w+)`\s*(?:\(([^)]*)\))?\s*VALUES\s*")

_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", "Z": "\x1a"}


def _parse_scalar(token: str) -> Value:
    if token == "NULL":
        return None
    try:
        return int(token)
    except ValueError:
        return float(token)


def parse_tuples(text: str, pos: int) -> tuple[list[list[Value]], int]:
    """Parse ``(a,'b',c),(d,...)...;`` starting at ``pos``. Returns rows and end position."""
    rows: list[list[Value]] = []
    n = len(text)
    while pos < n:
        ch = text[pos]
        if ch == ";":
            return rows, pos + 1
        if ch != "(":
            pos += 1
            continue
        pos += 1
        row: list[Value] = []
        while True:
            while text[pos] in " \t\r\n":
                pos += 1
            ch = text[pos]
            if ch == "'":
                pos += 1
                buf: list[str] = []
                while True:
                    c = text[pos]
                    if c == "\\":
                        nxt = text[pos + 1]
                        buf.append(_ESCAPES.get(nxt, nxt))
                        pos += 2
                    elif c == "'":
                        if text[pos + 1] == "'":  # doubled quote
                            buf.append("'")
                            pos += 2
                        else:
                            pos += 1
                            break
                    else:
                        buf.append(c)
                        pos += 1
                row.append("".join(buf))
            else:
                end = pos
                while text[end] not in ",)":
                    end += 1
                row.append(_parse_scalar(text[pos:end].strip()))
                pos = end
            if text[pos] == ",":
                pos += 1
                continue
            pos += 1  # closing ')'
            break
        rows.append(row)
    return rows, pos


class SqlDump:
    """Loads selected tables from a dump into lists of dict rows."""

    def __init__(self, path: Path, tables: set[str]) -> None:
        text = path.read_text(encoding="utf-8", errors="replace")
        self.columns: dict[str, list[str]] = {
            name: _COLUMN_RE.findall(body)
            for name, body in _CREATE_RE.findall(text)
            if name in tables
        }
        self.tables: dict[str, list[Row]] = {t: [] for t in tables}
        for match in _INSERT_RE.finditer(text):
            table = match.group(1)
            if table not in tables:
                continue
            rows, _ = parse_tuples(text, match.end())
            explicit = match.group(2)
            cols = [c.strip(" `") for c in explicit.split(",")] if explicit else self.columns[table]
            self.tables[table].extend(dict(zip(cols, r, strict=True)) for r in rows)

    def rows(self, table: str) -> Iterator[Row]:
        return iter(self.tables[table])
