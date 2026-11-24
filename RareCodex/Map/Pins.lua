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
-- Rares whose pins would cover each other on screen share one pin with a count
-- (Coords.Clusters): pins closer than this many pixels at the current zoom. Zooming in
-- splits them into their own pins.
local CLUSTER_PX = 16
-- Route colors of the rares sharing a pin while it is hovered, matched by a swatch in its
-- tooltip, so each route can be told apart.
local CLUSTER_COLORS = {
    { 1.0, 0.78, 0.15 }, { 0.25, 0.85, 1.0 }, { 1.0, 0.4, 0.85 },
    { 0.45, 1.0, 0.3 }, { 1.0, 0.45, 0.2 }, { 1.0, 1.0, 1.0 },
}

local function ColorsFor(groups)
    local colors = {}
    for i, group in ipairs(groups) do
        colors[group] = CLUSTER_COLORS[(i - 1) % #CLUSTER_COLORS + 1]
    end
    return colors
end

-- A pin stands for a cluster: one rare group, or several at (nearly) the same spot.
function RareCodexPinMixin:OnAcquired(cluster)
    self.cluster = cluster
    self.group = cluster.groups[1]
    self:SetPosition(cluster.x, cluster.y)
    local elite = false
    for _, group in ipairs(cluster.groups) do
        elite = elite or ns.Rares[group.npcID].elite and true or false
    end
    -- Rare elites use the game's elite vignette (star in a dragon frame), a bit bigger.
    local size = elite and ELITE_PIN_SIZE or PIN_SIZE
    self:SetSize(size, size)
    self.Icon:SetAtlas(elite and "VignetteKillElite" or "VignetteKill")
    self:UpdateStatus()
    self:SetPing(false)
    if #cluster.groups > 1 then
        self.Count:SetText(#cluster.groups)  -- number of rares sharing the pin
    else
        local showCount = ns.db.showSpawnCount and #self.group.entries > 1
        self.Count:SetText(showCount and #self.group.entries or "")
    end
end

-- The pin's status across its rares: seen if any was seen, dead only if all are dead (with
-- the soonest respawn), else nothing special.
local function ClusterStatus(cluster)
    local now, soonest, allDead = time(), nil, true
    for _, group in ipairs(cluster.groups) do
        local status = ns.RareStatus(ns.Rares[group.npcID], ns.PeekState(group.npcID), now)
        local kind = status and status.kind
        if kind == "seen" then return status end
        if kind == "dead" then
            if not soonest or status.from < soonest.from then soonest = status end
        else
            allDead = false
        end
    end
    return allDead and soonest or nil
end

-- Dead: dimmed with a countdown. Respawn window: normal. Seen alive just now: pulsing glow.
function RareCodexPinMixin:UpdateStatus()
    local status = ClusterStatus(self.cluster)
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
    local groups = self.cluster.groups
    local colors = #groups > 1 and ColorsFor(groups) or nil
    if colors then
        ns.Tooltip.ShowCluster(self, groups, colors)
    else
        ns.Tooltip.ShowRare(self, self.group.npcID)
    end
    ns.Overlay.Highlight(self:GetMap(), groups, colors)
    self:SetPing(true, true)
end

-- Menu to pick one of the rares sharing a pin; hovering an entry shows only its route.
local function ChooseRare(owner, groups)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        ns.DetailPanel.Show(groups[1].npcID)  -- client without the menu API
        return
    end
    local map, colors = owner:GetMap(), ColorsFor(groups)
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle(L["Rares here"])
        for _, group in ipairs(groups) do
            local rare = ns.Rares[group.npcID]
            local icon = ns.CreatureTypeIcon(rare, 14)
            local label = ("%s%s (%s)"):format(icon and (icon .. " ") or "",
                ns.GetName(group.npcID), ns.FormatColoredLevel(rare))
            local button = root:CreateButton(label, function() ns.DetailPanel.Show(group.npcID) end)
            if button.SetOnEnter and button.SetOnLeave then
                button:SetOnEnter(function()
                    ns.Overlay.Highlight(map, group, { [group] = colors[group] })
                end)
                button:SetOnLeave(function() ns.RestoreFocus() end)
            end
        end
    end)
end

function RareCodexPinMixin:OnMouseLeave()
    GameTooltip:Hide()
    self:SetPing(false)
    ns.RestoreFocus()
end

-- The map canvas routes clicks through OnMouseClickAction (newer clients) or OnMouseUp
-- (older ones). Both forward here; the timestamp check avoids handling one click twice.
function RareCodexPinMixin:HandleClick(button)
    local now = GetTime()
    if self.lastClick == now then return end
    self.lastClick = now
    local cluster = self.cluster
    if button == "LeftButton" and IsShiftKeyDown() then
        ns.SetWaypoint(self:GetMap():GetMapID(), cluster.x, cluster.y)
    elseif button == "LeftButton" and #cluster.groups > 1 then
        ChooseRare(self, cluster.groups)
    elseif button == "LeftButton" then
        ns.DetailPanel.Show(self.group.npcID)
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

-- Pins for the groups, clustered at the map's current zoom.
local function ClustersAtZoom(map, groups)
    local canvas, scale = map:GetCanvas(), math.max(map:GetCanvasScale(), 0.01)
    local width, height = canvas:GetWidth() * scale, canvas:GetHeight() * scale
    if width <= 0 or height <= 0 then return ns.Coords.Clusters(groups, 0) end
    return ns.Coords.Clusters(groups, CLUSTER_PX / width, CLUSTER_PX / height)
end

local function AcquirePins(map, clusters)
    for _, cluster in ipairs(clusters) do
        map:AcquirePin(PIN_TEMPLATE, cluster)
    end
end

function Provider:RefreshAllData()
    self:RemoveAllData()
    local map = self:GetMap()
    local mapID = map:GetMapID()
    local groups, scope = GroupsToShow(mapID)
    self.groups, self.clusterCount = groups, 0
    if groups then
        -- Routes and spawn dots only on zone maps: on continents they are unreadable and slow.
        if scope == "zone" then ns.Overlay.Draw(map, mapID, groups) end
        local clusters = ClustersAtZoom(map, groups)
        self.clusterCount = #clusters
        AcquirePins(map, clusters)
    end
    ns.RareList.SetGroups(map, groups)
    ns.RestoreFocus()
end

-- Zooming: line thickness follows at once; pins are clustered again once the zoom settles,
-- and only replaced when the clusters change.
local RECLUSTER_DELAY = 0.15
local reclusterToken = 0

function Provider:OnCanvasScaleChanged()
    local map = self:GetMap()
    ns.Overlay.UpdateThickness(map)
    reclusterToken = reclusterToken + 1
    local token = reclusterToken
    C_Timer.After(RECLUSTER_DELAY, function()
        if token ~= reclusterToken or not self.groups or not map:IsShown() then return end
        local clusters = ClustersAtZoom(map, self.groups)
        if #clusters == self.clusterCount then return end
        self.clusterCount = #clusters
        map:RemoveAllPinsByTemplate(PIN_TEMPLATE)
        AcquirePins(map, clusters)
        ns.RestoreFocus()
    end)
end

function ns.RefreshMap()
    if WorldMapFrame and WorldMapFrame:IsShown() then
        Provider:RefreshAllData()
    end
end

local function HasGroup(cluster, group)
    for _, g in ipairs(cluster.groups) do
        if g == group then return true end
    end
    return false
end

--- Pings the pin showing a rare group; nil goes back to the focused rare (ns.SetFocus).
function ns.PingRare(group)
    if not group then return ns.RestoreFocus() end
    if not (WorldMapFrame and WorldMapFrame:IsShown()) then return end
    for pin in WorldMapFrame:EnumeratePinsByTemplate(PIN_TEMPLATE) do
        pin:SetPing(HasGroup(pin.cluster, group))
    end
end

-- The rare open in the detail panel stays in focus on the map: its pin pings softly and its
-- route stays highlighted, so it is not lost among the other pins. Hovering other pins or
-- list rows shows them for a moment; leaving them comes back here.
local focusNpcID

function ns.SetFocus(npcID)
    focusNpcID = npcID
    ns.RestoreFocus()
end

function ns.RestoreFocus()
    if not (WorldMapFrame and WorldMapFrame:IsShown()) then return end
    local focusGroup
    for pin in WorldMapFrame:EnumeratePinsByTemplate(PIN_TEMPLATE) do
        local found
        for _, group in ipairs(pin.cluster.groups) do
            if group.npcID == focusNpcID then found = group end
        end
        pin:SetPing(found ~= nil, true)
        focusGroup = focusGroup or found
    end
    ns.Overlay.Highlight(WorldMapFrame, focusGroup)
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
