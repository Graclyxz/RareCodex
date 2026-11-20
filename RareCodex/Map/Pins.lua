-- Pins: world map data provider that places one pin per rare. Rares with several possible
-- spawn points get a count badge; the other points are drawn as dots by the overlay.
local _, ns = ...
local L = ns.L

local PIN_TEMPLATE = "RareCodexPinTemplate"

-- Global because Pins.xml references it by name.
RareCodexPinMixin = CreateFromMixins(MapCanvasPinMixin)

function RareCodexPinMixin:OnLoad()
    self:UseFrameLevelType("PIN_FRAME_LEVEL_VIGNETTE")
    self:SetScalingLimits(1, 1.0, 1.25)
end

-- The map canvas calls SetPassThroughButtons on every pin it acquires
-- (MapCanvasPinMixin:CheckMouseButtonPassthrough). That frame method is protected in combat,
-- so opening the map while fighting raised ADDON_ACTION_BLOCKED for our pins. They handle
-- every mouse button themselves (see HandleClick), so pass-through is not needed: this
-- override shadows the protected method and does nothing.
function RareCodexPinMixin:SetPassThroughButtons() end

function RareCodexPinMixin:OnAcquired(group)
    self.group = group
    self:SetPosition(group.primary.x, group.primary.y)
    local rare = ns.Rares[group.npcID]
    self.Icon:SetAtlas(rare.elite and "VignetteKillElite" or "VignetteKill")
    local showCount = ns.db.showSpawnCount and #group.entries > 1
    self.Count:SetText(showCount and #group.entries or "")
end

function RareCodexPinMixin:OnMouseEnter()
    ns.Tooltip.ShowRare(self, self.group.npcID)
    ns.Overlay.Highlight(self:GetMap(), self.group)
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
    local group = self.group
    if button == "LeftButton" and IsShiftKeyDown() then
        ns.SetWaypoint(self:GetMap():GetMapID(), group.primary.x, group.primary.y)
    elseif button == "LeftButton" then
        ns.DetailPanel.Show(group.npcID)
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
    local groups = ns.Coords.GroupsForMap(mapID)
    -- Routes and spawn dots only on zone maps: on continents they are unreadable and expensive.
    if scope == "zone" then ns.Overlay.Draw(map, mapID, groups) end
    for _, group in ipairs(groups) do
        map:AcquirePin(PIN_TEMPLATE, group)
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
        ns.Print(L["Waypoints are not allowed on this map."])
        return
    end
    C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(uiMapID, x, y))
    C_SuperTrack.SetSuperTrackedUserWaypoint(true)
end

ns.On("PLAYER_LOGIN", function()
    WorldMapFrame:AddDataProvider(Provider)
end)
