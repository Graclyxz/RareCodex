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
    showList = true,         -- list of the map's rares, on the world map
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

local function ColorCode(r, g, b)
    return ("|cff%02x%02x%02x"):format(r * 255, g * 255, b * 255)
end

-- CMaNGOS creature type IDs (rare.ctype), see the header of Data/Rares.lua. Icons are the
-- battle pet family icons where one exists; demons and giants have no pet family.
local CREATURE_TYPES = {
    [1] = { L["Beast"], "Icon_PetFamily_Beast", 0.85, 0.6, 0.35 },
    [2] = { L["Dragonkin"], "Icon_PetFamily_Dragon", 1.0, 0.45, 0.25 },
    [3] = { L["Demon"], "Spell_Shadow_SummonImp", 0.7, 0.4, 1.0 },
    [4] = { L["Elemental"], "Icon_PetFamily_Elemental", 0.35, 0.7, 1.0 },
    [5] = { L["Giant"], "Ability_GolemThunderClap", 0.8, 0.75, 0.6 },
    [6] = { L["Undead"], "Icon_PetFamily_Undead", 0.6, 0.9, 0.6 },
    [7] = { L["Humanoid"], "Icon_PetFamily_Humanoid", 1.0, 0.85, 0.6 },
    [8] = { L["Critter"], "Icon_PetFamily_Critter", 0.75, 0.75, 0.75 },
    [9] = { L["Mechanical"], "Icon_PetFamily_Mechanical", 0.6, 0.8, 0.85 },
}

--- Inline icon of the rare's creature type, nil when unknown.
function ns.CreatureTypeIcon(rare, iconSize)
    local info = CREATURE_TYPES[rare.ctype]
    if not info then return nil end
    -- Crop the icon border (5..59 of 64) so it blends with the text.
    return ("|TInterface\\Icons\\%s:%d:%d:0:0:64:64:5:59:5:59|t"):format(
        info[2], iconSize or 14, iconSize or 14)
end

--- Inline icon plus colored name of the rare's creature type, nil when unknown.
function ns.FormatCreatureType(rare, iconSize)
    local info = CREATURE_TYPES[rare.ctype]
    if not info then return nil end
    return ns.CreatureTypeIcon(rare, iconSize) .. " "
        .. ColorCode(info[3], info[4], info[5]) .. info[1] .. "|r"
end

-- Same colors the game uses for mob levels: grey, green, yellow, orange, red.
local function LevelColor(level)
    local getColor = GetCreatureDifficultyColor or GetQuestDifficultyColor
    local color = getColor and level and getColor(level)
    return color and ColorCode(color.r, color.g, color.b)
end

--- The rare's level colored by difficulty for the player.
function ns.FormatColoredLevel(rare)
    local level = ns.FormatLevel(rare)
    local levelColor = LevelColor(rare.level and rare.level[2])
    return levelColor and (levelColor .. level .. "|r") or level
end

--- "Level 9 Rare · Beast": the level colored by difficulty for the player.
function ns.FormatLevelLine(rare, rankColor)
    local rank = ns.FormatRank(rare)
    if rankColor then rank = rankColor .. rank .. "|r" end
    local line = L["Level %s %s"]:format(ns.FormatColoredLevel(rare), rank)
    local creatureType = ns.FormatCreatureType(rare)
    return creatureType and (line .. " · " .. creatureType) or line
end

--- Countdown text: "1h 20m", "35m" or "<1m".
function ns.FormatTimer(seconds)
    if seconds < 60 then return "<1m" end
    local minutes = math.floor(seconds / 60)
    if minutes < 60 then return ("%dm"):format(minutes) end
    return ("%dh %02dm"):format(math.floor(minutes / 60), minutes % 60)
end

local RECENTLY_SEEN = 5 * 60
-- A sighting this long after the death means it respawned (a corpse can keep its vignette
-- for a few minutes, so sightings right after the death do not count).
local ALIVE_AFTER_DEATH = 10 * 60

--- Respawn state of a rare from what this character saw:
---   { kind = "seen", ago }            alive a moment ago
---   { kind = "dead", from, to }       respawns in from..to seconds
---   { kind = "window", to }           may respawn now, at the latest in `to` seconds
--- or nil when nothing is known (never seen dead, or its respawn time is long past).
function ns.RareStatus(rare, state, now)
    if not state then return nil end
    local seen, death = state.lastSeen, state.lastDeath
    local aliveAgain = seen and (not death or seen - death > ALIVE_AFTER_DEATH)
    if aliveAgain and now - seen < RECENTLY_SEEN then
        return { kind = "seen", ago = now - seen }
    end
    if not death or aliveAgain or not rare.respawn then return nil end
    local elapsed = now - death
    local low, high = rare.respawn[1], rare.respawn[2]
    if elapsed < low then return { kind = "dead", from = low - elapsed, to = high - elapsed } end
    if elapsed < high then return { kind = "window", to = high - elapsed } end
    return nil
end

--- One line describing ns.RareStatus, colored; nil when there is nothing to say.
function ns.FormatStatus(status)
    if not status then return nil end
    if status.kind == "seen" then
        return "|cff33ff66" .. L["Seen alive %s"]:format(ns.FormatAgo(time() - status.ago)) .. "|r"
    elseif status.kind == "dead" then
        local from, to = ns.FormatTimer(status.from), ns.FormatTimer(status.to)
        local range = from == to and from or (from .. " - " .. to)
        return "|cffff6666" .. L["Dead, respawns in %s"]:format(range) .. "|r"
    end
    return "|cffffd200" .. L["May be up now (at the latest in %s)"]:format(
        ns.FormatTimer(status.to)) .. "|r"
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
