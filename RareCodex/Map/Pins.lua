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

local PIN_SIZE, ELITE_PIN_SIZE = 22, 26

function RareCodexPinMixin:OnAcquired(group)
    self.group = group
    self:SetPosition(group.primary.x, group.primary.y)
    local rare = ns.Rares[group.npcID]
    -- Rare elites use the game's elite vignette (star in a dragon frame), a bit bigger.
    local size = rare.elite and ELITE_PIN_SIZE or PIN_SIZE
    self:SetSize(size, size)
    self.Icon:SetAtlas(rare.elite and "VignetteKillElite" or "VignetteKill")
    self:UpdateStatus()
    self:SetPing(false)
    local showCount = ns.db.showSpawnCount and #group.entries > 1
    self.Count:SetText(showCount and #group.entries or "")
end

-- Dead: dimmed with a countdown. Respawn window: normal. Seen alive just now: pulsing glow.
function RareCodexPinMixin:UpdateStatus()
    local npcID = self.group.npcID
    local status = ns.RareStatus(ns.Rares[npcID], ns.PeekState(npcID), time())
    local kind = status and status.kind
    self.Icon:SetDesaturated(kind == "dead")
    self.Icon:SetAlpha(kind == "dead" and 0.55 or 1)
    self.Timer:SetText(kind == "dead" and ns.FormatTimer(status.from) or "")
    self.Glow:SetShown(kind == "seen")
    if kind == "seen" then
        if not self.GlowPulse:IsPlaying() then self.GlowPulse:Play() end
    else
        self.GlowPulse:Stop()
    end
end

-- Ping rings around the pin, to find a rare hovered in the rare list among many pins.
-- Soft: a smaller, fainter ring without the glow, for the pin under the mouse.
local PING_SIZE, SOFT_PING_SIZE = 72, 44

function RareCodexPinMixin:SetPing(on, soft)
    local ping = self.Ping
    ping:SetShown(on)
    if on then
        ping:SetFrameLevel(self:GetFrameLevel() + 20)  -- above the neighbouring pins
        ping:SetAlpha(soft and 0.6 or 1)
        local size = soft and SOFT_PING_SIZE or PING_SIZE
        ping.Ring1:SetSize(size, size)
        ping.Halo:SetShown(not soft)
        ping.Waves:Play()
        ping.Breath:Play()
    else
        ping.Waves:Stop()
        ping.Breath:Stop()
    end
end

function RareCodexPinMixin:OnMouseEnter()
    ns.Tooltip.ShowRare(self, self.group.npcID)
    ns.Overlay.Highlight(self:GetMap(), self.group)
    self:SetPing(true, true)
end

function RareCodexPinMixin:OnMouseLeave()
    GameTooltip:Hide()
    self:SetPing(false)
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

-- Groups (one per rare) of the map being shown, or nil when its pins are turned off.
local function GroupsToShow(mapID)
    if not mapID or not ns.db then return nil end
    local scope = ns.Coords.ScopeOfMap(mapID)
    if not scope or not ns.db.show[scope] then return nil end
    return ns.Coords.GroupsForMap(mapID), scope
end

function Provider:RefreshAllData()
    self:RemoveAllData()
    local map = self:GetMap()
    local mapID = map:GetMapID()
    local groups, scope = GroupsToShow(mapID)
    if groups then
        -- Routes and spawn dots only on zone maps: on continents they are unreadable and slow.
        if scope == "zone" then ns.Overlay.Draw(map, mapID, groups) end
        for _, group in ipairs(groups) do
            map:AcquirePin(PIN_TEMPLATE, group)
        end
    end
    ns.RareList.SetGroups(map, groups)
end

function Provider:OnCanvasScaleChanged()
    ns.Overlay.UpdateThickness(self:GetMap())
end

function ns.RefreshMap()
    if WorldMapFrame and WorldMapFrame:IsShown() then
        Provider:RefreshAllData()
    end
end

--- Pings the pin of a rare group (nil stops every ping).
function ns.PingRare(group)
    if not (WorldMapFrame and WorldMapFrame:IsShown()) then return end
    for pin in WorldMapFrame:EnumeratePinsByTemplate(PIN_TEMPLATE) do
        pin:SetPing(group ~= nil and pin.group == group)
    end
end

--- Updates the status of the pins and list on screen (cheap: no redraw of routes or pins).
function ns.RefreshPins()
    if not (WorldMapFrame and WorldMapFrame:IsShown()) then return end
    for pin in WorldMapFrame:EnumeratePinsByTemplate(PIN_TEMPLATE) do
        pin:UpdateStatus()
    end
    ns.RareList.Update()
end

function ns.SetWaypoint(uiMapID, x, y)
    if not C_Map.CanSetUserWaypointOnMap(uiMapID) then
        ns.Print(L["Waypoints are not allowed on this map."])
        return
    end
    C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(uiMapID, x, y))
    C_SuperTrack.SetSuperTrackedUserWaypoint(true)
end

-- Countdowns tick while the map is open (RefreshPins returns at once when it is closed).
local STATUS_INTERVAL = 15

ns.On("PLAYER_LOGIN", function()
    WorldMapFrame:AddDataProvider(Provider)
    C_Timer.NewTicker(STATUS_INTERVAL, ns.RefreshPins)
end)
