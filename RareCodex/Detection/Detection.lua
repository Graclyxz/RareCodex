-- Detection: notices rares (vignettes, target, mouseover) and records kills and loot.
-- Rares missing from the database (e.g. WoW Forever additions) are recorded in
-- RareCodexDB.unknown (sightings, patrol tracks, level) so players can share them (/rc share).
local _, ns = ...
local L = ns.L

local ALERT_COOLDOWN = 5 * 60
-- Two sightings on the same map closer than this (normalized map units) are one spot.
local SAME_SPOT = 0.01
local RARE_CLASSIFICATIONS = { rare = false, rareelite = true }  -- value = is elite
local lastAlert = {}

-- Tracking: while an unknown rare's vignette is on the minimap its position is sampled, so a
-- moving rare yields a patrol track instead of a trail of fake spawn points.
local TRACK_INTERVAL = 2      -- seconds between samples
local TRACK_MIN_STEP = 0.001  -- normalized map units; smaller moves are not stored
local TRACK_LOST_AFTER = 6    -- seconds without a position before the encounter ends
local TRACK_MAX_POINTS = 300
local MAX_TRACKS_PER_RARE = 10
local tracking = {}           -- [vignetteGUID] = { npcID, mapID, points = {x1, y1, ...}, seen }
local ticker

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
    if ns.RefreshPins then ns.RefreshPins() end
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

local function IsTrackingRare(npcID)
    for _, encounter in pairs(tracking) do
        if encounter.npcID == npcID then return true end
    end
    return false
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
    -- One sighting per encounter: later positions of a rare being tracked are its movement,
    -- not other spawn points.
    if (vignetteGUID and tracking[vignetteGUID]) or IsTrackingRare(npcID) then return end
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

-- Tracks ---------------------------------------------------------------------------
local function StoreTrack(encounter)
    local record = ns.db.unknown[encounter.npcID]
    if not record or #encounter.points < 4 then return end  -- needs at least two points
    record.tracks = record.tracks or {}
    table.insert(record.tracks, { mapID = encounter.mapID, points = encounter.points, time = time() })
    if #record.tracks > MAX_TRACKS_PER_RARE then
        -- Keep the most informative tracks: drop the one with the fewest points.
        local shortest = 1
        for i, track in ipairs(record.tracks) do
            if #track.points < #record.tracks[shortest].points then shortest = i end
        end
        table.remove(record.tracks, shortest)
    end
end

local function StopTracking(vignetteGUID)
    local encounter = tracking[vignetteGUID]
    if not encounter then return end
    tracking[vignetteGUID] = nil
    StoreTrack(encounter)
    if not next(tracking) and ticker then
        ticker:Cancel()
        ticker = nil
    end
end

local function SampleTracks()
    local now = GetTime()
    local playerMap = C_Map.GetBestMapForUnit("player")
    for vignetteGUID, encounter in pairs(tracking) do
        local pos = playerMap == encounter.mapID
            and C_VignetteInfo.GetVignettePosition(vignetteGUID, encounter.mapID)
        if pos then
            encounter.seen = now
            local x, y = pos:GetXY()
            local points = encounter.points
            local n = #points
            local moved = n == 0 or (x - points[n - 1]) ^ 2 + (y - points[n]) ^ 2 >= TRACK_MIN_STEP ^ 2
            if moved and n < 2 * TRACK_MAX_POINTS then
                points[n + 1] = x
                points[n + 2] = y
            end
        elseif now - encounter.seen > TRACK_LOST_AFTER then
            StopTracking(vignetteGUID)
        end
    end
end

local function StartTracking(vignetteGUID, npcID)
    if tracking[vignetteGUID] then return end
    local mapID = C_Map.GetBestMapForUnit("player")
    if not mapID then return end
    tracking[vignetteGUID] = { npcID = npcID, mapID = mapID, points = {}, seen = GetTime() }
    SampleTracks()
    ticker = ticker or C_Timer.NewTicker(TRACK_INTERVAL, SampleTracks)
end

-- Exposed for the offline test suite (tests/test_lua_detection.py).
ns.Detection = { _StoreTrack = StoreTrack, _tracking = tracking }

local function CheckVignette(vignetteGUID)
    local info = C_VignetteInfo.GetVignetteInfo(vignetteGUID)
    if not info or not info.objectGUID then return end
    local npcID = ns.NpcIDFromGUID(info.objectGUID)
    if not npcID then return end
    if ns.Rares[npcID] then
        if not info.isDead then MarkSeen(npcID) end  -- a corpse does not mean it respawned
        Alert(npcID, ns.GetName(npcID), npcID)
    elseif info.atlasName and info.atlasName:find("VignetteKill", 1, true) then
        RecordUnknown(npcID, info.name, vignetteGUID)
        StartTracking(vignetteGUID, npcID)
        Alert(npcID, info.name or "?", nil)
    end
end

ns.On("VIGNETTE_MINIMAP_UPDATED", function(vignetteGUID, onMinimap)
    if onMinimap then
        CheckVignette(vignetteGUID)
    else
        StopTracking(vignetteGUID)
    end
end)

-- Leaving the zone or logging out ends every encounter; tracks recorded so far are kept.
local function StopAll()
    for vignetteGUID in pairs(tracking) do StopTracking(vignetteGUID) end
end
ns.On("ZONE_CHANGED_NEW_AREA", StopAll)
ns.On("PLAYER_LOGOUT", StopAll)

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
        local dead = UnitIsDead(unit)
        if not ns.IsSecret(dead) and not dead then MarkSeen(npcID) end
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

-- Kills and loot ----------------------------------------------------------------------
-- Drop chances are drops / kills, so kills that drop nothing must count too: a kill is
-- counted when a rare we may loot dies (seen through target, focus, mouseover or a
-- nameplate) and, as a fallback, when its corpse is looted. Each creature (GUID) counts once.

-- Deaths (ours or anyone's) start the respawn timer. Only the first sighting of each corpse
-- counts, so finding the corpse again later does not move the timer.
local deaths = {}  -- [creatureGUID] = true, this session

local function RecordDeath(guid, npcID)
    if deaths[guid] then return end
    deaths[guid] = true
    local state = ns.GetState(npcID)
    state.lastDeath = ns.db.killed[guid] or time()
    if ns.RefreshPins then ns.RefreshPins() end
end

local function CountKill(guid, npcID)
    if ns.db.killed[guid] then return end
    ns.db.killed[guid] = time()
    local state = ns.GetState(npcID)
    state.kills = state.kills + 1
    state.lastSeen = time()
    RecordDeath(guid, npcID)
    if ns.DetailPanel.Refresh then ns.DetailPanel.Refresh(npcID) end
end

-- A dead rare is ours when it is not tapped by someone else (grey name), i.e. we or our
-- group may loot it.
local function CheckDeath(unit)
    local guid = UnitGUID(unit)
    local npcID = ns.NpcIDFromGUID(guid)
    if not npcID or not IsTracked(npcID) or ns.db.killed[guid] then return end
    local dead, denied = UnitIsDead(unit), UnitIsTapDenied(unit)
    if ns.IsSecret(dead) or ns.IsSecret(denied) or not dead then return end
    if denied then
        RecordDeath(guid, npcID)  -- killed by someone else: no kill, but the timer starts
    else
        CountKill(guid, npcID)
    end
end

local WATCHED_UNITS = { target = true, focus = true, mouseover = true }
ns.On("UNIT_HEALTH", function(unit)
    if WATCHED_UNITS[unit] or (unit and unit:find("^nameplate")) then CheckDeath(unit) end
end)
ns.On("PLAYER_TARGET_CHANGED", function() CheckDeath("target") end)

-- Drops are tallied once per corpse; looting also counts the kill if the death was missed.
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
        CountKill(guid, entry.npcID)
        local state = ns.GetState(entry.npcID)
        for _, itemID in ipairs(entry.items) do
            state.loot[itemID] = (state.loot[itemID] or 0) + 1
        end
        if ns.DetailPanel.Refresh then ns.DetailPanel.Refresh(entry.npcID) end
    end
end)
