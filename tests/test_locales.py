"""Every L["..."] used by the addon must be translated, with matching format specifiers."""

import re
from pathlib import Path

import pytest

ADDON = Path(__file__).resolve().parent.parent / "RareCodex"
LOCALES = ADDON / "Locales"
TRANSLATIONS = ["esES.lua"]

_KEY = re.compile(r'L\["((?:[^"\\]|\\.)*)"\]')
_ENTRY = re.compile(r'^L\["((?:[^"\\]|\\.)*)"\]\s*=\s*"((?:[^"\\]|\\.)*)"', re.M)
_SPEC = re.compile(r"%[-+ #0]*\d*(?:\.\d+)?[sdfi%]")


def used_keys() -> set[str]:
    keys: set[str] = set()
    for path in ADDON.rglob("*.lua"):
        if LOCALES not in path.parents:
            keys |= set(_KEY.findall(path.read_text(encoding="utf-8")))
    return keys


def translations(name: str) -> dict[str, str]:
    return dict(_ENTRY.findall((LOCALES / name).read_text(encoding="utf-8")))


@pytest.mark.parametrize("name", TRANSLATIONS)
def test_every_used_key_is_translated(name: str) -> None:
    missing = sorted(used_keys() - translations(name).keys())
    assert not missing, f"{name} lacks: {missing}"


@pytest.mark.parametrize("name", TRANSLATIONS)
def test_no_stale_translations(name: str) -> None:
    stale = sorted(translations(name).keys() - used_keys())
    assert not stale, f"{name} has unused keys: {stale}"


@pytest.mark.parametrize("name", TRANSLATIONS)
def test_format_specifiers_match(name: str) -> None:
    for key, text in translations(name).items():
        assert _SPEC.findall(key) == _SPEC.findall(text), key


if __name__ == "__main__":
    for k in sorted(used_keys()):
        print(k)
