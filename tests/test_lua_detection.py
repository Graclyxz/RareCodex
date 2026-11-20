"""Runs Detection/Detection.lua with a simulated vignette that moves across the map.

Regression for the first real submission: a walking rare was saved as several spawn points.
It must give one sighting plus one patrol track.
"""

from pathlib import Path

import pytest
from lupa import LuaRuntime

DETECTION = Path(__file__).resolve().parent.parent / "RareCodex" / "Detection" / "Detection.lua"

STUBS = """
local Vec = {}
Vec.__index = Vec
function Vec:GetXY() return self.x, self.y end
local function V(x, y) return setmetatable({ x = x, y = y }, Vec) end

now = 100
vignette = { x = 0.50, y = 0.50, visible = true }
tickers = {}

function GetTime() return now end
time = function() return 1700000000 + now end
C_Map = {
    GetBestMapForUnit = function() return 1414 end,
    GetPlayerMapPosition = function() return V(0.1, 0.1) end,
}
C_VignetteInfo = {
    GetVignettes = function() return { "vig-1" } end,
    GetVignetteInfo = function()
        return { objectGUID = "Creature-0-0-0-0-900001-0000000000", atlasName = "VignetteKill",
                 name = "Eck'alom", onMinimap = vignette.visible }
    end,
    GetVignettePosition = function()
        if vignette.visible then return V(vignette.x, vignette.y) end
    end,
}
C_Timer = { NewTicker = function(_, fn)
    local t = { fn = fn, cancelled = false }
    function t:Cancel() self.cancelled = true end
    table.insert(tickers, t)
    return t
end }
function tick() for _, t in ipairs(tickers) do if not t.cancelled then t.fn() end end end
PlaySound = function() end
SOUNDKIT = { RAID_WARNING = 1 }
RaidNotice_AddMessage = function() end
ChatTypeInfo = { RAID_WARNING = {} }

-- Units: units[token] = { guid, dead, denied }
units = {}
function UnitGUID(unit) return units[unit] and units[unit].guid end
function UnitIsDead(unit) return units[unit] and units[unit].dead or false end
function UnitIsTapDenied(unit) return units[unit] and units[unit].denied or false end
function UnitClassification() return "normal" end

-- Loot window: loot = { { item = id or nil, guid = source } }
loot = {}
function GetNumLootItems() return #loot end
function GetLootSlotLink(slot) return loot[slot].item and tostring(loot[slot].item) end
function GetLootSourceInfo(slot) return loot[slot].guid, 1 end
C_Item = { GetItemInfoInstant = function(link) return tonumber(link) end }
"""

NS = """
local handlers = {}
ns = {
    L = setmetatable({}, { __index = function(_, k) return k end }),
    db = { alerts = false, unknown = {}, npcs = {}, killed = {}, looted = {} },
    Rares = { [3736] = { name = "Mordenthal" } },
    Contribute = { OnNewRare = function() end },
    DetailPanel = {},
    IsSecret = function() return false end,
    Print = function() end,
    On = function(event, fn)
        handlers[event] = handlers[event] or {}
        table.insert(handlers[event], fn)
    end,
    NpcIDFromGUID = function(guid)
        return guid and tonumber((select(6, strsplit("-", guid))))
    end,
    GetState = function(id)
        ns.db.npcs[id] = ns.db.npcs[id] or { kills = 0, loot = {} }
        return ns.db.npcs[id]
    end,
}
function fire(event, ...) for _, fn in ipairs(handlers[event] or {}) do fn(...) end end
function strsplit(sep, s)
    local out = {}
    for part in (s .. sep):gmatch("(.-)" .. sep) do out[#out + 1] = part end
    return unpack(out)
end
unpack = unpack or table.unpack
"""


@pytest.fixture
def lua() -> LuaRuntime:
    runtime = LuaRuntime()
    runtime.execute(STUBS)
    runtime.execute(NS)
    load = runtime.eval("function(src) return load(src, 'Detection.lua') end")
    load(DETECTION.read_text(encoding="utf-8"))("RareCodex", runtime.globals().ns)
    return runtime


def step(lua: LuaRuntime, x: float, y: float) -> None:
    """The rare walks; the minimap refreshes (as it does constantly) and the ticker fires."""
    lua.execute(f"vignette.x, vignette.y = {x}, {y}; now = now + 2")
    lua.execute("fire('VIGNETTES_UPDATED')")
    lua.execute("tick()")


def test_walking_rare_gives_one_sighting_and_one_track(lua: LuaRuntime) -> None:
    lua.execute("fire('VIGNETTE_MINIMAP_UPDATED', 'vig-1', true)")
    for i in range(1, 6):
        step(lua, 0.50 + 0.02 * i, 0.50)  # 0.02 per step: far beyond the sighting threshold
    lua.execute("vignette.visible = false; fire('VIGNETTE_MINIMAP_UPDATED', 'vig-1', false)")

    record = lua.eval("ns.db.unknown[900001]")
    assert record.name == "Eck'alom"
    assert len(record.sightings) == 1
    assert len(record.tracks) == 1
    points = list(record.tracks[1].points.values())
    assert points[:2] == [0.5, 0.5] and points[-2:] == [pytest.approx(0.6), 0.5]
    assert len(points) == 12  # start + 5 moves, x/y each
    assert lua.eval("tickers[1].cancelled") is True


def test_standing_rare_stores_no_track(lua: LuaRuntime) -> None:
    lua.execute("fire('VIGNETTE_MINIMAP_UPDATED', 'vig-1', true)")
    for _ in range(3):
        step(lua, 0.5, 0.5)
    lua.execute("vignette.visible = false; fire('VIGNETTE_MINIMAP_UPDATED', 'vig-1', false)")
    record = lua.eval("ns.db.unknown[900001]")
    assert len(record.sightings) == 1
    assert record.tracks is None


def test_lost_vignette_ends_the_encounter(lua: LuaRuntime) -> None:
    lua.execute("fire('VIGNETTE_MINIMAP_UPDATED', 'vig-1', true)")
    step(lua, 0.55, 0.5)
    lua.execute("vignette.visible = false")  # vanishes without a minimap event
    for _ in range(5):
        lua.execute("now = now + 2; tick()")
    assert len(lua.eval("ns.db.unknown[900001]").tracks) == 1


# --- kills -----------------------------------------------------------------------------
RARE_GUID = "Creature-0-0-0-0-3736-00000000AA"


def kills(lua: LuaRuntime) -> int:
    state = lua.eval("ns.db.npcs[3736]")
    return state.kills if state else 0


def test_kill_without_loot_is_counted_once(lua: LuaRuntime) -> None:
    lua.execute(f"units.target = {{ guid = '{RARE_GUID}', dead = false }}")
    lua.execute("fire('UNIT_HEALTH', 'target')")
    assert kills(lua) == 0  # still alive
    lua.execute("units.target.dead = true")
    for _ in range(3):
        lua.execute("fire('UNIT_HEALTH', 'target')")
    lua.execute("fire('PLAYER_TARGET_CHANGED')")
    assert kills(lua) == 1


def test_rare_tapped_by_someone_else_is_not_our_kill(lua: LuaRuntime) -> None:
    lua.execute(f"units.nameplate3 = {{ guid = '{RARE_GUID}', dead = true, denied = true }}")
    lua.execute("fire('UNIT_HEALTH', 'nameplate3')")
    assert kills(lua) == 0


def test_looting_after_the_death_adds_drops_but_not_another_kill(lua: LuaRuntime) -> None:
    lua.execute(f"units.target = {{ guid = '{RARE_GUID}', dead = true }}")
    lua.execute("fire('UNIT_HEALTH', 'target')")
    slots = ", ".join(f"{{ item = {item}, guid = '{RARE_GUID}' }}" for item in (2592, 4606))
    lua.execute(f"loot = {{ {slots} }}")
    lua.execute("fire('LOOT_READY'); fire('LOOT_READY')")  # the event can fire twice
    assert kills(lua) == 1
    assert dict(lua.eval("ns.db.npcs[3736].loot").items()) == {2592: 1, 4606: 1}


def test_looting_counts_the_kill_when_the_death_was_not_seen(lua: LuaRuntime) -> None:
    lua.execute(f"loot = {{ {{ item = 2592, guid = '{RARE_GUID}' }} }}")
    lua.execute("fire('LOOT_READY')")
    assert kills(lua) == 1
