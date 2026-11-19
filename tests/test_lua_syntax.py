"""Compile every addon Lua file to catch syntax errors outside the game client."""

from pathlib import Path

import pytest
from lupa import LuaRuntime

ADDON = Path(__file__).resolve().parent.parent / "RareCodex"
LUA_FILES = sorted(ADDON.rglob("*.lua"))


@pytest.mark.parametrize("path", LUA_FILES, ids=lambda p: str(p.relative_to(ADDON)))
def test_lua_file_compiles(path: Path) -> None:
    lua = LuaRuntime()
    compile_chunk = lua.eval("function(src, name) local f, err = load(src, name) return err end")
    assert compile_chunk(path.read_text(encoding="utf-8"), path.name) is None


def test_toc_lists_existing_files() -> None:
    toc = (ADDON / "RareCodex.toc").read_text(encoding="utf-8").splitlines()
    files = [line.strip() for line in toc if line.strip() and not line.startswith("#")]
    for name in files:
        assert (ADDON / name.replace("\\", "/")).is_file(), name
