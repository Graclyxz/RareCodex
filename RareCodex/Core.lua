-- Core: namespace, event dispatch, saved variables and shared helpers.
local addonName, ns = ...
local L = ns.L

ns.name = addonName
ns.Rares = ns.Rares or {}

local DEFAULTS = {
    version = 1,
    npcs = {},          -- [npcID] = { lastSeen, kills, loot = { [itemID] = count } }
    looted = {},        -- [creatureGUID] = timestamp, avoids double counting a corpse's drops
    killed = {},        -- [creatureGUID] = timestamp, avoids double counting a kill
    unknown = {},       -- rares seen in game that are not in the database (Forever additions)
    axisSwapped = nil,  -- world coordinate order, set by Coords.Calibrate()
    show = { zone = true, continent = false, world = false },  -- pins per map scope
    showPaths = true,
    showSpawnCount = false,  -- number of possible spawn points on the pin
    showSpawnArea = false,   -- outline enclosing all of a rare's possible spawn points
    alerts = true,
    contributeReminders = true,  -- clickable chat message to share recorded rares
}

-- Fills missing keys (including inside nested tables) without touching saved values.
local function ApplyDefaults(saved, defaults)
    for key, value in pairs(defaults) do
        if type(value) == "table" then
            saved[key] = type(saved[key]) == "table" and saved[key] or {}
            ApplyDefaults(saved[key], value)
        elseif saved[key] == nil then
            saved[key] = value
        end
    end
end

local LOOTED_GUID_TTL = 24 * 60 * 60

-- Event dispatch -------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
local handlers = {}

function ns.On(event, fn)
    if not handlers[event] then
        handlers[event] = {}
        eventFrame:RegisterEvent(event)
    end
    table.insert(handlers[event], fn)
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    for _, fn in ipairs(handlers[event]) do
        fn(...)
    end
end)

-- Saved variables --------------------------------------------------------------
ns.On("ADDON_LOADED", function(name)
    if name ~= addonName then return end
    RareCodexDB = RareCodexDB or {}
    ApplyDefaults(RareCodexDB, DEFAULTS)
    local now = time()
    for _, seen in ipairs({ RareCodexDB.looted, RareCodexDB.killed }) do
        for guid, stamp in pairs(seen) do
            if now - stamp > LOOTED_GUID_TTL then seen[guid] = nil end
        end
    end
    ns.db = RareCodexDB
end)

-- Helpers ----------------------------------------------------------------------
local function IsSecret(value)
    return issecretvalue ~= nil and issecretvalue(value)
end
ns.IsSecret = IsSecret

function ns.NpcIDFromGUID(guid)
    if not guid or IsSecret(guid) then return nil end
    local unitType, _, _, _, _, npcID = strsplit("-", guid)
    if unitType == "Creature" or unitType == "Vehicle" then
        return tonumber(npcID)
    end
end

function ns.GetState(npcID)
    local state = ns.db.npcs[npcID]
    if not state then
        state = { kills = 0, loot = {} }
        ns.db.npcs[npcID] = state
    end
    return state
end

function ns.PeekState(npcID)
    return ns.db and ns.db.npcs[npcID]
end

local nameCache = {}
--- Localized creature name from the client cache, falling back to the English DB name.
function ns.GetName(npcID)
    if nameCache[npcID] then return nameCache[npcID] end
    local link = ("unit:Creature-0-0-0-0-%d-0000000000"):format(npcID)
    local data = C_TooltipInfo and C_TooltipInfo.GetHyperlink(link)
    local line = data and data.lines and data.lines[1]
    local name = line and line.leftText
    if name and name ~= "" and not IsSecret(name) then
        nameCache[npcID] = name
        return name
    end
    local rare = ns.Rares[npcID]
    return rare and rare.name or ("NPC " .. npcID)
end

function ns.FormatDuration(seconds)
    if seconds >= 3600 then
        local hours = seconds / 3600
        return (hours == math.floor(hours) and "%dh" or "%.1fh"):format(hours)
    end
    return ("%dm"):format(math.floor(seconds / 60))
end

-- Rares recorded in game (rare.unknown) have no respawn or level data.
function ns.FormatRespawn(rare)
    if not rare.respawn then return L["Unknown"] end
    local low, high = rare.respawn[1], rare.respawn[2]
    if low == high then return ns.FormatDuration(low) end
    return ns.FormatDuration(low) .. " - " .. ns.FormatDuration(high)
end

function ns.FormatLevel(rare)
    if not rare.level then return "?" end
    if rare.level[1] == rare.level[2] then return tostring(rare.level[1]) end
    return rare.level[1] .. "-" .. rare.level[2]
end

function ns.FormatRank(rare)
    return rare.elite and L["Rare Elite"] or L["Rare"]
end

function ns.FormatAgo(stamp)
    local delta = time() - stamp
    if delta < 60 then return L["just now"] end
    return L["%s ago"]:format(ns.FormatDuration(delta))
end

function ns.FormatChance(chance)
    if chance >= 10 then return ("%d%%"):format(math.floor(chance + 0.5)) end
    if chance >= 1 then return ("%.1f%%"):format(chance) end
    if chance >= 0.01 then return ("%.2f%%"):format(chance) end
    return "<0.01%"
end

function ns.Print(msg)
    print("|cff33ccffRareCodex|r: " .. msg)  -- addon name is not translated
end

-- Slash commands ---------------------------------------------------------------
local function FindRare(query)
    local id = tonumber(query)
    if id then return ns.Rares[id] and id end
    query = query:lower()
    for npcID in pairs(ns.Rares) do
        if ns.GetName(npcID):lower():find(query, 1, true) then return npcID end
    end
end

local function OnOff(value)
    return value and L["on"] or L["off"]
end

-- Translation keys stay literal (not built at runtime) so tests/test_locales.py can check
-- that every one is translated.
local HELP = {
    { "/rc <name | npcID>", L["open the details of a rare"] },
    { "/rc config", L["open the options"] },
    { "/rc show zone | continent | world", L["toggle pins per map type"] },
    { "/rc paths", L["toggle patrol routes"] },
    { "/rc alerts", L["toggle rare alerts"] },
    { "/rc share", L["share rares recorded in game that are not in the database"] },
    { "/rc check", L["verify map coordinates"] },
    { "/rc swap", L["flip coordinate axes"] },
}
local SCOPE_NAMES = { zone = L["zone"], continent = L["continent"], world = L["world"] }

SLASH_RARECODEX1 = "/rarecodex"
SLASH_RARECODEX2 = "/rc"
SlashCmdList.RARECODEX = function(input)
    input = strtrim(input or "")
    local command = input:lower()
    local scope = command:match("^show (%a+)$")
    if command == "" then
        ns.Print(L["Commands:"])
        for _, entry in ipairs(HELP) do
            print(("  |cffffd200%s|r - %s"):format(entry[1], entry[2]))
        end
    elseif command == "config" then
        ns.OpenOptions()
    elseif command == "share" or command == "export" then
        ns.Contribute.Show()
    elseif scope and SCOPE_NAMES[scope] then
        ns.db.show[scope] = not ns.db.show[scope]
        ns.RefreshMap()
        ns.Print(L["Pins on %s maps: %s"]:format(SCOPE_NAMES[scope], OnOff(ns.db.show[scope])))
    elseif command == "check" then
        ns.Coords.Calibrate(true)
    elseif command == "swap" then
        ns.db.axisSwapped = not ns.db.axisSwapped
        ns.Coords.Invalidate()
        ns.Print(L["Coordinate axes swapped: %s"]:format(OnOff(ns.db.axisSwapped)))
    elseif command == "paths" then
        ns.db.showPaths = not ns.db.showPaths
        ns.RefreshMap()
        ns.Print(L["Patrol routes: %s"]:format(OnOff(ns.db.showPaths)))
    elseif command == "alerts" then
        ns.db.alerts = not ns.db.alerts
        ns.Print(L["Alerts: %s"]:format(OnOff(ns.db.alerts)))
    else
        local npcID = FindRare(input)
        if npcID then
            ns.DetailPanel.Show(npcID)
        else
            ns.Print(L["No rare found for '%s'"]:format(input))
        end
    end
end
