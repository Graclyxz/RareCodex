-- Detection: notices rares (vignettes, target, mouseover) and records kills and loot.
local _, ns = ...

local ALERT_COOLDOWN = 5 * 60
local lastAlert = {}

local function Alert(key, name, npcID)
    if not ns.db.alerts then return end
    local now = GetTime()
    if lastAlert[key] and now - lastAlert[key] < ALERT_COOLDOWN then return end
    lastAlert[key] = now
    PlaySound(SOUNDKIT.RAID_WARNING)
    RaidNotice_AddMessage(RaidWarningFrame, "Rare nearby: " .. name, ChatTypeInfo.RAID_WARNING)
    if npcID then
        ns.Print(("Rare nearby: |cffffd200%s|r - type /rc %d for details"):format(name, npcID))
    else
        ns.Print(("Rare nearby: |cffffd200%s|r (not in database yet, recorded)"):format(name))
    end
end

local function MarkSeen(npcID)
    ns.GetState(npcID).lastSeen = time()
end

-- Rares the database does not know (e.g. WoW Forever additions) are stored so they
-- can be added later.
local function RecordUnknown(npcID, name)
    local mapID = C_Map.GetBestMapForUnit("player")
    local pos = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
    local record = ns.db.unknown[npcID] or { name = name, sightings = {} }
    ns.db.unknown[npcID] = record
    if pos then
        local x, y = pos:GetXY()
        table.insert(record.sightings, { mapID = mapID, x = x, y = y, time = time() })
    end
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
        RecordUnknown(npcID, info.name)
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

local function CheckUnit(unit)
    local npcID = ns.NpcIDFromGUID(UnitGUID(unit))
    if npcID and ns.Rares[npcID] then MarkSeen(npcID) end
end

ns.On("PLAYER_TARGET_CHANGED", function() CheckUnit("target") end)
ns.On("UPDATE_MOUSEOVER_UNIT", function() CheckUnit("mouseover") end)

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
            if npcID and ns.Rares[npcID] and not ns.db.looted[guid] then
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
