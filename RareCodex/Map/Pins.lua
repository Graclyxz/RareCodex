-- Pins: world map data provider that places one pin per rare spawn point.
local _, ns = ...

local PIN_TEMPLATE = "RareCodexPinTemplate"

-- Global because Pins.xml references it by name.
RareCodexPinMixin = CreateFromMixins(MapCanvasPinMixin)

function RareCodexPinMixin:OnLoad()
    self:UseFrameLevelType("PIN_FRAME_LEVEL_VIGNETTE")
    self:SetScalingLimits(1, 1.0, 1.25)
end

function RareCodexPinMixin:OnAcquired(entry)
    self.entry = entry
    self:SetPosition(entry.x, entry.y)
    local rare = ns.Rares[entry.npcID]
    self.Icon:SetAtlas(rare.elite and "VignetteKillElite" or "VignetteKill")
end

function RareCodexPinMixin:OnMouseEnter()
    ns.Tooltip.ShowRare(self, self.entry.npcID)
    ns.Overlay.Highlight(self:GetMap(), self.entry)
end

function RareCodexPinMixin:OnMouseLeave()
    GameTooltip:Hide()
    ns.Overlay.Highlight(self:GetMap(), nil)
end

-- The map canvas routes clicks through OnMouseClickAction (newer clients) or OnMouseUp
-- (older ones). Both forward here; the timestamp check avoids handling one click twice.
function RareCodexPinMixin:HandleClick(button)
    local now = GetTime()
    if self.lastClick == now then return end
    self.lastClick = now
    local entry = self.entry
    if button == "LeftButton" and IsShiftKeyDown() then
        ns.SetWaypoint(self:GetMap():GetMapID(), entry.x, entry.y)
    elseif button == "LeftButton" then
        ns.DetailPanel.Show(entry.npcID)
    elseif button == "RightButton" then
        local map = self:GetMap()
        if map.NavigateToParentMap then map:NavigateToParentMap() end
    end
end

function RareCodexPinMixin:OnMouseClickAction(button)
    self:HandleClick(button)
end

function RareCodexPinMixin:OnMouseUp(button, upInside)
    if upInside ~= false then self:HandleClick(button) end
end

local Provider = CreateFromMixins(MapCanvasDataProviderMixin)

function Provider:RemoveAllData()
    self:GetMap():RemoveAllPinsByTemplate(PIN_TEMPLATE)
    ns.Overlay.Clear()
end

function Provider:RefreshAllData()
    self:RemoveAllData()
    local map = self:GetMap()
    local mapID = map:GetMapID()
    if not mapID or not ns.db then return end
    local scope = ns.Coords.ScopeOfMap(mapID)
    if not scope or not ns.db.show[scope] then return end
    local entries = ns.Coords.EntriesForMap(mapID)
    -- Patrol lines only on zone maps: on continents they are unreadable and expensive.
    if scope == "zone" then ns.Overlay.Draw(map, mapID, entries) end
    for _, entry in ipairs(entries) do
        map:AcquirePin(PIN_TEMPLATE, entry)
    end
end

function Provider:OnCanvasScaleChanged()
    ns.Overlay.UpdateThickness(self:GetMap())
end

function ns.RefreshMap()
    if WorldMapFrame and WorldMapFrame:IsShown() then
        Provider:RefreshAllData()
    end
end

function ns.SetWaypoint(uiMapID, x, y)
    if not C_Map.CanSetUserWaypointOnMap(uiMapID) then
        ns.Print("Waypoints are not allowed on this map.")
        return
    end
    C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(uiMapID, x, y))
    C_SuperTrack.SetSuperTrackedUserWaypoint(true)
end

ns.On("PLAYER_LOGIN", function()
    WorldMapFrame:AddDataProvider(Provider)
end)
