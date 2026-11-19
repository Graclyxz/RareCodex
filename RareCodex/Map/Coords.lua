-- Coords: converts database world coordinates into normalized UI map positions.
local _, ns = ...

local Coords = {}
ns.Coords = Coords

local WANDER_SEGMENTS = 16
local CALIBRATION_MAX_ERROR = 1e-4

local zoneCache = {}   -- [spawn] = zone uiMapID under the spawn point, or false
local entryCache = {}  -- [uiMapID] = list of { npcID, spawn, x, y }

local SCOPE_BY_MAP_TYPE = {
    [Enum.UIMapType.World] = "world",
    [Enum.UIMapType.Continent] = "continent",
    [Enum.UIMapType.Zone] = "zone",
    [Enum.UIMapType.Micro] = "zone",
}

local function WorldVector(wx, wy)
    if ns.db.axisSwapped then
        return CreateVector2D(wy, wx)
    end
    return CreateVector2D(wx, wy)
end

--- Normalized position of a world point on uiMapID (may fall outside 0..1).
function Coords.WorldToMap(instanceID, wx, wy, uiMapID)
    local _, pos = C_Map.GetMapPosFromWorldPos(instanceID, WorldVector(wx, wy), uiMapID)
    if pos then return pos:GetXY() end
end

--- "zone", "continent", "world" or nil for maps where rares are never shown.
function Coords.ScopeOfMap(uiMapID)
    local info = C_Map.GetMapInfo(uiMapID)
    return info and SCOPE_BY_MAP_TYPE[info.mapType]
end

local function ContinentOfMap(uiMapID)
    local info = C_Map.GetMapInfo(uiMapID)
    while info do
        if info.mapType == Enum.UIMapType.Continent then return info.mapID end
        info = info.parentMapID and info.parentMapID > 0 and C_Map.GetMapInfo(info.parentMapID)
    end
end

local function InstanceOfMap(uiMapID)
    local instanceID = C_Map.GetWorldPosFromMapPos(uiMapID, CreateVector2D(0.5, 0.5))
    return instanceID
end

-- Zone under a spawn point, resolved on the continent map the same way the world map
-- highlights the zone under the cursor.
local function ZoneOf(spawn, continentID)
    local zone = zoneCache[spawn]
    if zone == nil then
        local x, y = Coords.WorldToMap(spawn[1], spawn[2], spawn[3], continentID)
        local info = x and C_Map.GetMapInfoAtPosition(continentID, x, y)
        zone = info and info.mapID or false
        zoneCache[spawn] = zone
    end
    return zone or nil
end

local function IsSelfOrAncestor(ancestorID, mapID)
    while mapID and mapID > 0 do
        if mapID == ancestorID then return true end
        local info = C_Map.GetMapInfo(mapID)
        mapID = info and info.parentMapID
    end
    return false
end

--- The zone map a spawn belongs to (used by the detail panel's map buttons).
function Coords.ZoneOfSpawn(spawn)
    -- Without an override map this returns a broad map (the continent in practice).
    local mapID = C_Map.GetMapPosFromWorldPos(spawn[1], WorldVector(spawn[2], spawn[3]))
    local continentID = mapID and ContinentOfMap(mapID)
    return continentID and ZoneOf(spawn, continentID)
end

--- Every rare spawn point shown on uiMapID. Zone maps only keep spawns inside the zone;
--- continent and world maps keep everything that falls within their bounds.
function Coords.EntriesForMap(uiMapID)
    local cached = entryCache[uiMapID]
    if cached then return cached end
    local entries = {}
    local scope = Coords.ScopeOfMap(uiMapID)
    -- World maps span several instances, so they are not filtered by instance.
    local instanceID = scope ~= "world" and InstanceOfMap(uiMapID)
    local continentID = scope == "zone" and ContinentOfMap(uiMapID)
    if scope and (scope == "world" or instanceID) and (scope ~= "zone" or continentID) then
        for npcID, rare in pairs(ns.Rares) do
            for _, spawn in ipairs(rare.spawns) do
                if not instanceID or spawn[1] == instanceID then
                    local x, y = Coords.WorldToMap(spawn[1], spawn[2], spawn[3], uiMapID)
                    local inBounds = x and x >= 0 and x <= 1 and y >= 0 and y <= 1
                    if inBounds and (scope ~= "zone"
                            or IsSelfOrAncestor(uiMapID, ZoneOf(spawn, continentID))) then
                        entries[#entries + 1] = { npcID = npcID, spawn = spawn, x = x, y = y }
                    end
                end
            end
        end
    end
    entryCache[uiMapID] = entries
    return entries
end

--- Flat list {x1, y1, x2, y2, ...} describing the spawn's patrol path or wander area.
--- Returns points, isClosed.
function Coords.ShapeForSpawn(spawn, uiMapID)
    local points = {}
    if spawn.path then
        local path = spawn.path
        for i = 1, #path, 2 do
            local x, y = Coords.WorldToMap(spawn[1], path[i], path[i + 1], uiMapID)
            if x then
                points[#points + 1] = x
                points[#points + 1] = y
            end
        end
        local n = #path
        local dx, dy = path[1] - path[n - 1], path[2] - path[n]
        return points, (dx * dx + dy * dy) < 100  -- last point within 10 yards of the first
    elseif spawn.wander then
        for i = 0, WANDER_SEGMENTS - 1 do
            local angle = 2 * math.pi * i / WANDER_SEGMENTS
            local x, y = Coords.WorldToMap(spawn[1],
                spawn[2] + spawn.wander * math.cos(angle),
                spawn[3] + spawn.wander * math.sin(angle), uiMapID)
            if x then
                points[#points + 1] = x
                points[#points + 1] = y
            end
        end
        return points, true
    end
    return points, false
end

function Coords.Invalidate()
    wipe(zoneCache)
    wipe(entryCache)
    if ns.RefreshMap then ns.RefreshMap() end
end

--- Detect the world-vector axis order by comparing against the player's real map position.
function Coords.Calibrate(verbose)
    local a, b, _, instanceID = UnitPosition("player")
    if not a or ns.IsSecret(a) then
        if verbose then ns.Print("Calibration unavailable here (UnitPosition restricted).") end
        return false
    end
    local mapID = C_Map.GetBestMapForUnit("player")
    local playerPos = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
    if not playerPos then
        if verbose then ns.Print("Calibration unavailable: no player map position.") end
        return false
    end
    local px, py = playerPos:GetXY()
    local function ErrorFor(vector)
        local _, pos = C_Map.GetMapPosFromWorldPos(instanceID, vector, mapID)
        if not pos then return math.huge end
        local x, y = pos:GetXY()
        return (x - px) ^ 2 + (y - py) ^ 2
    end
    -- Database order is (serverX, serverY); UnitPosition returns serverX first.
    local direct, swapped = ErrorFor(CreateVector2D(a, b)), ErrorFor(CreateVector2D(b, a))
    local best = math.min(direct, swapped)
    if verbose then
        ns.Print(("Calibration: direct error %.6f, swapped error %.6f, current setting: %s"):format(
            direct, swapped, ns.db.axisSwapped and "swapped" or "direct"))
    end
    if best > CALIBRATION_MAX_ERROR then
        if verbose then ns.Print("Neither axis order matches; please report this.") end
        return false
    end
    local isSwapped = swapped < direct
    if ns.db.axisSwapped ~= isSwapped then
        ns.db.axisSwapped = isSwapped
        Coords.Invalidate()
    end
    return true
end

ns.On("PLAYER_ENTERING_WORLD", function()
    if ns.db.axisSwapped == nil then Coords.Calibrate(false) end
end)
ns.On("ZONE_CHANGED_NEW_AREA", function()
    if ns.db.axisSwapped == nil then Coords.Calibrate(false) end
end)
