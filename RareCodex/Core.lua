-- Core: namespace, event dispatch, saved variables and shared helpers.
local addonName, ns = ...

ns.name = addonName
ns.Rares = ns.Rares or {}

local DEFAULTS = {
    version = 1,
    npcs = {},          -- [npcID] = { lastSeen, kills, loot = { [itemID] = count } }
    looted = {},        -- [creatureGUID] = timestamp, avoids double counting a corpse
    unknown = {},       -- rares seen in game that are not in the database (Forever additions)
    axisSwapped = nil,  -- world coordinate order, set by Coords.Calibrate()
    show = { zone = true, continent = false, world = false },  -- pins per map scope
    showPaths = true,
    showSpawnCount = false,  -- number of possible spawn points on the pin
    showSpawnArea = false,   -- outline enclosing all of a rare's possible spawn points
    alerts = true,
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
    for guid, stamp in pairs(RareCodexDB.looted) do
        if now - stamp > LOOTED_GUID_TTL then RareCodexDB.looted[guid] = nil end
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

function ns.FormatRespawn(rare)
    local low, high = rare.respawn[1], rare.respawn[2]
    if low == high then return ns.FormatDuration(low) end
    return ns.FormatDuration(low) .. " - " .. ns.FormatDuration(high)
end

function ns.FormatAgo(stamp)
    local delta = time() - stamp
    if delta < 60 then return "just now" end
    return ns.FormatDuration(delta) .. " ago"
end

function ns.FormatChance(chance)
    if chance >= 10 then return ("%d%%"):format(math.floor(chance + 0.5)) end
    if chance >= 1 then return ("%.1f%%"):format(chance) end
    if chance >= 0.01 then return ("%.2f%%"):format(chance) end
    return "<0.01%"
end

function ns.Print(msg)
    print("|cff33ccffRareCodex|r: " .. msg)
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

SLASH_RARECODEX1 = "/rarecodex"
SLASH_RARECODEX2 = "/rc"
SlashCmdList.RARECODEX = function(input)
    input = strtrim(input or "")
    local command = input:lower()
    local scope = command:match("^show (%a+)$")
    if command == "" then
        ns.Print("/rc <name or npcID> - open details | /rc config - options"
            .. " | /rc show zone|continent|world - toggle pins per map type"
            .. " | /rc paths - toggle patrol lines | /rc alerts - toggle alerts"
            .. " | /rc check - verify map coordinates | /rc swap - flip coordinate axes")
    elseif command == "config" then
        ns.OpenOptions()
    elseif scope and ns.db.show[scope] ~= nil then
        ns.db.show[scope] = not ns.db.show[scope]
        ns.RefreshMap()
        ns.Print(("Pins on %s maps: %s"):format(scope, ns.db.show[scope] and "on" or "off"))
    elseif command == "check" then
        ns.Coords.Calibrate(true)
    elseif command == "swap" then
        ns.db.axisSwapped = not ns.db.axisSwapped
        ns.Coords.Invalidate()
        ns.Print("Axis order swapped: " .. tostring(ns.db.axisSwapped))
    elseif command == "paths" then
        ns.db.showPaths = not ns.db.showPaths
        ns.RefreshMap()
        ns.Print("Patrol lines " .. (ns.db.showPaths and "on" or "off"))
    elseif command == "alerts" then
        ns.db.alerts = not ns.db.alerts
        ns.Print("Alerts " .. (ns.db.alerts and "on" or "off"))
    else
        local npcID = FindRare(input)
        if npcID then
            ns.DetailPanel.Show(npcID)
        else
            ns.Print("No rare found for '" .. input .. "'")
        end
    end
end
