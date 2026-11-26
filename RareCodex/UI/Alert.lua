-- Alert: toast shown when a rare appears on the minimap - portrait, name, level, live
-- distance, and buttons to set a waypoint or open its details. Drag it to move it.
local _, ns = ...
local L = ns.L

local AlertToast = {}
ns.AlertToast = AlertToast

local WIDTH, HEIGHT = 330, 92
local PORTRAIT = 72
local DURATION = 45          -- seconds before it hides by itself
local UPDATE_INTERVAL = 0.5  -- distance refresh

local toast
local shown = {}  -- npcID, name, vignetteGUID, expires

-- Where the rare is now: the vignette's position on the player's map, or nil when the
-- vignette is gone (the rare died or went out of range).
local function RarePosition()
    local mapID = C_Map.GetBestMapForUnit("player")
    if not mapID or not shown.vignetteGUID then return nil end
    local pos = C_VignetteInfo.GetVignettePosition(shown.vignetteGUID, mapID)
    if not pos or ns.IsSecret(pos) then return nil end
    return mapID, pos
end

-- Distance in yards between the player and the rare, from their world positions.
local function Distance()
    local mapID, rarePos = RarePosition()
    if not mapID then return nil end
    local playerPos = C_Map.GetPlayerMapPosition(mapID, "player")
    if not playerPos then return nil end
    local _, a = C_Map.GetWorldPosFromMapPos(mapID, rarePos)
    local _, b = C_Map.GetWorldPosFromMapPos(mapID, playerPos)
    if not a or not b then return nil end
    local ax, ay = a:GetXY()
    local bx, by = b:GetXY()
    return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2)
end

-- First line: "Rare nearby! · 85 yards away".
local function UpdateDistance()
    local yards = Distance()
    local distance = yards and L["%d yards away"]:format(yards) or L["Out of sight"]
    toast.Header:SetText(L["Rare nearby!"] .. "  |cffb3b3b3·  " .. distance .. "|r")
end

-- Entrance: the toast pops in (slightly bigger, settling to its size) while fading in, then
-- a gold ring of light glows along its inner edge three times.
local FLASHES = 3
local GLOW_SIZE = 16  -- how far the inner glow reaches from each edge

local function CreateAnimations()
    local intro = toast:CreateAnimationGroup()
    local fade = intro:CreateAnimation("Alpha")
    fade:SetFromAlpha(0)
    fade:SetToAlpha(1)
    fade:SetDuration(0.2)
    local pop = intro:CreateAnimation("Scale")
    if pop.SetScaleFrom then
        pop:SetScaleFrom(1.18, 1.18)
        pop:SetScaleTo(1, 1)
    else
        pop:SetScale(1 / 1.18, 1 / 1.18)
    end
    pop:SetDuration(0.3)
    pop:SetSmoothing("OUT")
    toast.Intro = intro

    -- Inner glow: a strip along each edge, bright at the border and fading toward the
    -- middle, on a frame above the portrait and buttons (it does not take the mouse).
    local glow = CreateFrame("Frame", nil, toast)
    glow:SetPoint("TOPLEFT", 5, -5)
    glow:SetPoint("BOTTOMRIGHT", -5, 5)
    glow:SetFrameLevel(toast:GetFrameLevel() + 20)
    glow:SetAlpha(0)
    local edge, clear = CreateColor(1, 0.82, 0.3, 0.95), CreateColor(1, 0.82, 0.3, 0)
    local function Strip(point1, point2, horizontal, edgeFirst)
        local strip = glow:CreateTexture(nil, "OVERLAY")
        strip:SetTexture("Interface\\Buttons\\WHITE8X8")
        strip:SetBlendMode("ADD")
        strip:SetPoint(point1)
        strip:SetPoint(point2)
        if horizontal then strip:SetWidth(GLOW_SIZE) else strip:SetHeight(GLOW_SIZE) end
        -- SetGradient goes from the left/bottom color to the right/top one.
        local orientation = horizontal and "HORIZONTAL" or "VERTICAL"
        strip:SetGradient(orientation, edgeFirst and edge or clear, edgeFirst and clear or edge)
    end
    Strip("TOPLEFT", "TOPRIGHT", false, false)       -- top: bright at the top
    Strip("BOTTOMLEFT", "BOTTOMRIGHT", false, true)  -- bottom: bright at the bottom
    Strip("TOPLEFT", "BOTTOMLEFT", true, true)       -- left: bright at the left
    Strip("TOPRIGHT", "BOTTOMRIGHT", true, false)    -- right: bright at the right
    toast.Flash = glow

    local flash = glow:CreateAnimationGroup()
    for i = 1, FLASHES do
        local up = flash:CreateAnimation("Alpha")
        up:SetFromAlpha(0)
        up:SetToAlpha(1)
        up:SetDuration(0.18)
        up:SetOrder(2 * i - 1)
        local down = flash:CreateAnimation("Alpha")
        down:SetFromAlpha(1)
        down:SetToAlpha(0)
        down:SetDuration(0.4)
        down:SetOrder(2 * i)
    end
    -- End dark: keep the last step's alpha (0) and force it, whether it finished or was
    -- cut short by a new alert.
    if flash.SetToFinalAlpha then flash:SetToFinalAlpha(true) end
    local function Off() glow:SetAlpha(0) end
    flash:SetScript("OnFinished", Off)
    flash:SetScript("OnStop", Off)
    toast.FlashAnim = flash
end

local function SetWaypoint()
    local mapID, pos = RarePosition()
    if mapID then
        ns.SetWaypoint(mapID, pos.x, pos.y)
    elseif ns.Rares[shown.npcID] then
        ns.DetailPanel.SetWaypoint(shown.npcID)  -- vignette gone: its database spawn
    end
end

local function SavePosition()
    local point, _, relativePoint, x, y = toast:GetPoint()
    local saved = ns.db.alertPosition
    saved.point, saved.relativePoint, saved.x, saved.y = point, relativePoint, x, y
end

local function Create()
    toast = CreateFrame("Frame", "RareCodexAlertToast", UIParent, "BackdropTemplate")
    toast:SetSize(WIDTH, HEIGHT)
    toast:SetFrameStrata("HIGH")
    toast:SetClampedToScreen(true)
    toast:SetMovable(true)
    toast:EnableMouse(true)  -- drag it anywhere; only the Details button opens the details
    toast:RegisterForDrag("LeftButton")
    toast:SetScript("OnDragStart", toast.StartMoving)
    toast:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition()
    end)
    toast:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border",
        edgeSize = 20, insets = { left = 5, right = 5, top = 5, bottom = 5 },
    })
    toast:SetBackdropColor(0.04, 0.04, 0.04, 0.92)
    local saved = ns.db.alertPosition
    if saved.point then
        toast:SetPoint(saved.point, UIParent, saved.relativePoint, saved.x, saved.y)
    else
        toast:SetPoint("TOP", UIParent, "TOP", 0, -150)
    end

    toast.Model = CreateFrame("PlayerModel", nil, toast)
    toast.Model:SetSize(PORTRAIT, PORTRAIT)
    toast.Model:SetPoint("LEFT", 10, 0)

    toast.Header = toast:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    toast.Header:SetPoint("TOPLEFT", toast.Model, "TOPRIGHT", 10, -2)
    toast.Name = toast:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    toast.Name:SetPoint("TOPLEFT", toast.Header, "BOTTOMLEFT", 0, -3)
    toast.Name:SetPoint("RIGHT", -28, 0)
    toast.Name:SetJustifyH("LEFT")
    toast.Name:SetWordWrap(false)
    toast.Level = toast:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    toast.Level:SetPoint("TOPLEFT", toast.Name, "BOTTOMLEFT", 0, -3)

    toast.Close = CreateFrame("Button", nil, toast, "UIPanelCloseButton")
    toast.Close:SetSize(24, 24)
    toast.Close:SetPoint("TOPRIGHT", -2, -2)
    toast.Close:SetScript("OnClick", function() toast:Hide() end)

    toast.Waypoint = CreateFrame("Button", nil, toast, "UIPanelButtonTemplate")
    toast.Waypoint:SetText(L["Waypoint"])
    toast.Waypoint:SetSize(math.max(80, toast.Waypoint:GetTextWidth() + 20), 20)
    toast.Waypoint:SetPoint("BOTTOMRIGHT", -10, 9)
    toast.Waypoint:SetScript("OnClick", SetWaypoint)
    toast.Details = CreateFrame("Button", nil, toast, "UIPanelButtonTemplate")
    toast.Details:SetText(L["Details"])
    toast.Details:SetSize(math.max(80, toast.Details:GetTextWidth() + 20), 20)
    toast.Details:SetPoint("RIGHT", toast.Waypoint, "LEFT", -4, 0)
    toast.Details:SetScript("OnClick", function() ns.DetailPanel.Show(shown.npcID) end)


    local elapsed = 0
    toast:SetScript("OnUpdate", function(self, delta)
        elapsed = elapsed + delta
        if elapsed < UPDATE_INTERVAL then return end
        elapsed = 0
        if GetTime() > shown.expires and not self:IsMouseOver() then
            self:Hide()
            return
        end
        UpdateDistance()
    end)
    CreateAnimations()
    toast:Hide()
end

--- Shows the toast for a rare; `npcID` is nil for rares that are not in the database.
function AlertToast.Show(name, npcID, vignetteGUID)
    if not toast then Create() end
    shown.npcID, shown.name, shown.vignetteGUID = npcID, name, vignetteGUID
    shown.expires = GetTime() + DURATION

    local rare = npcID and ns.Rares[npcID]
    local color = rare and rare.elite and "|cffffd200" or "|cff66ccff"
    toast.Name:SetText(color .. name .. "|r")
    toast.Level:SetText(rare and ns.FormatLevelLine(rare) or L["Not in the database yet (recorded)"])
    toast.Details:SetShown(rare ~= nil)

    toast.Model:ClearModel()
    if rare and rare.display then
        toast.Model:SetDisplayInfo(rare.display)
    elseif npcID then
        toast.Model:SetCreature(npcID)
    end
    if toast.Model.SetPortraitZoom then toast.Model:SetPortraitZoom(0.9) end

    UpdateDistance()
    toast:Show()
    toast.Intro:Stop()
    toast.Intro:Play()
    toast.FlashAnim:Stop()
    toast.FlashAnim:Play()
    -- Master channel: heard even with game sound effects turned down.
    PlaySound(SOUNDKIT.RAID_WARNING, "Master")
end

--- Back to its default place (top of the screen).
function AlertToast.ResetPosition()
    local saved = ns.db.alertPosition
    saved.point, saved.relativePoint, saved.x, saved.y = nil, nil, nil, nil
    if toast then
        toast:ClearAllPoints()
        toast:SetPoint("TOP", UIParent, "TOP", 0, -150)
    end
end
