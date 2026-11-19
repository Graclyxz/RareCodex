-- Detection: notices rares (vignettes, target, mouseover) and records kills and loot.
-- Rares missing from the database (e.g. WoW Forever additions) are recorded in
-- RareCodexDB.unknown so they can be exported with /rc export and added to the data.
local _, ns = ...
local L = ns.L

local ALERT_COOLDOWN = 5 * 60
-- Two sightings on the same map closer than this (normalized map units) are one spot.
local SAME_SPOT = 0.01
local RARE_CLASSIFICATIONS = { rare = false, rareelite = true }  -- value = is elite
local lastAlert = {}

local function Alert(key, name, npcID)
    if not ns.db.alerts then return end
    local now = GetTime()
    if lastAlert[key] and now - lastAlert[key] < ALERT_COOLDOWN then return end
    lastAlert[key] = now
    PlaySound(SOUNDKIT.RAID_WARNING)
    RaidNotice_AddMessage(RaidWarningFrame, L["Rare nearby: %s"]:format(name), ChatTypeInfo.RAID_WARNING)
    if npcID then
        ns.Print(L["Rare nearby: |cffffd200%s|r - type /rc %d for details"]:format(name, npcID))
    else
        ns.Print(L["Rare nearby: |cffffd200%s|r (not in the database yet, recorded)"]:format(name))
    end
end

local function MarkSeen(npcID)
    ns.GetState(npcID).lastSeen = time()
end

-- Where the rare is: the vignette's own position when available, else the player's.
local function SightingPosition(vignetteGUID)
    local mapID = C_Map.GetBestMapForUnit("player")
    if not mapID then return end
    local pos = vignetteGUID and C_VignetteInfo.GetVignettePosition(vignetteGUID, mapID)
    pos = pos or C_Map.GetPlayerMapPosition(mapID, "player")
    if not pos then return end
    local x, y = pos:GetXY()
    return mapID, x, y
end

local function RecordUnknown(npcID, name, vignetteGUID, details)
    local record = ns.db.unknown[npcID]
    if not record then
        record = { sightings = {} }
        ns.db.unknown[npcID] = record
        ns.Contribute.OnNewRare(name)
    end
    record.name = name or record.name
    if details then
        record.level, record.elite = details.level, details.elite
    end
    MarkSeen(npcID)
    local mapID, x, y = SightingPosition(vignetteGUID)
    if not mapID then return end
    for _, s in ipairs(record.sightings) do
        if s.mapID == mapID and (s.x - x) ^ 2 + (s.y - y) ^ 2 < SAME_SPOT ^ 2 then
            s.time = time()
            return
        end
    end
    table.insert(record.sightings, { mapID = mapID, x = x, y = y, time = time() })
end

local function CheckVignette(vignetteGUID)
    local info = C_VignetteInfo.GetVignetteInfo(vignetteGUID)
    if not info or not info.objectGUID then return end
    local npcID = ns.NpcIDFromGUID(info.objectGUID)
    if not npcID then return end
    if ns.Rares[npcID] then
        MarkSeen(npcID)
        Alert(npcID, ns.GetName(npcID), npcID)
    elseif info.atlasName and info.atlasName:find("VignetteKill", 1, true) then
        RecordUnknown(npcID, info.name, vignetteGUID)
        Alert(npcID, info.name or "?", nil)
    end
end

ns.On("VIGNETTE_MINIMAP_UPDATED", function(vignetteGUID, onMinimap)
    if onMinimap then CheckVignette(vignetteGUID) end
end)

ns.On("VIGNETTES_UPDATED", function()
    for _, vignetteGUID in ipairs(C_VignetteInfo.GetVignettes()) do
        local info = C_VignetteInfo.GetVignetteInfo(vignetteGUID)
        if info and info.onMinimap then CheckVignette(vignetteGUID) end
    end
end)

-- Targeting or hovering a rare also gives its level and rank, which vignettes lack.
local function CheckUnit(unit)
    local npcID = ns.NpcIDFromGUID(UnitGUID(unit))
    if not npcID then return end
    if ns.Rares[npcID] then
        MarkSeen(npcID)
        return
    end
    local classification = UnitClassification(unit)
    if ns.IsSecret(classification) or RARE_CLASSIFICATIONS[classification] == nil then return end
    local level, name = UnitLevel(unit), UnitName(unit)
    if ns.IsSecret(level) or ns.IsSecret(name) then return end
    RecordUnknown(npcID, name, nil, { level = level, elite = RARE_CLASSIFICATIONS[classification] })
end

ns.On("PLAYER_TARGET_CHANGED", function() CheckUnit("target") end)
ns.On("UPDATE_MOUSEOVER_UNIT", function() CheckUnit("mouseover") end)

local function IsTracked(npcID)
    return ns.Rares[npcID] or ns.db.unknown[npcID]
end

-- A kill is counted the first time a rare's corpse is looted; drops are tallied per item.
ns.On("LOOT_READY", function()
    local itemsBySource = {}
    for slot = 1, GetNumLootItems() do
        local link = GetLootSlotLink(slot)
        local itemID = link and C_Item.GetItemInfoInstant(link)
        local sources = { GetLootSourceInfo(slot) }
        for i = 1, #sources, 2 do
            local guid = sources[i]
            local npcID = ns.NpcIDFromGUID(guid)
            if npcID and IsTracked(npcID) and not ns.db.looted[guid] then
                local entry = itemsBySource[guid] or { npcID = npcID, items = {} }
                itemsBySource[guid] = entry
                if itemID then entry.items[#entry.items + 1] = itemID end
            end
        end
    end
    for guid, entry in pairs(itemsBySource) do
        ns.db.looted[guid] = time()
        local state = ns.GetState(entry.npcID)
        state.kills = state.kills + 1
        state.lastSeen = time()
        for _, itemID in ipairs(entry.items) do
            state.loot[itemID] = (state.loot[itemID] or 0) + 1
        end
        if ns.DetailPanel.Refresh then ns.DetailPanel.Refresh(entry.npcID) end
    end
end)
