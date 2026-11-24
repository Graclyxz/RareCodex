-- RareList: side panel next to the world map listing the rares of the map being viewed, so
-- the map itself stays clear. A side tab on the map's right edge (under other addons' tabs)
-- opens it; hovering a row highlights the rare's pin and route, clicking opens its details.
local _, ns = ...
local L = ns.L

local RareList = {}
ns.RareList = RareList

local WIDTH = 250
local ROW_H = 20
local HEADER_H = 30
local INSET = 6
local SCROLLBAR_W = 22
local TAB_TOP = 30       -- first side tab slot, below the top of the map's frame (as the game's)
local TAB_GAP = 3        -- between side tabs stacked down the edge
local PANEL_GAP = 2
local TAB_ICON = "Interface\\Icons\\INV_Misc_Book_09"

-- Lower sorts first: rares that may be up before the ones known to be dead.
local STATUS_ORDER = { seen = 1, window = 2, none = 3, dead = 4 }

local map, groups = nil, {}
local frame, tab
local rows = {}

--- Rows for the given groups (one per rare) sorted by status, then level, then name.
--- Pure function: exposed for tests/test_lua_rarelist.py.
function RareList.SortedEntries(groupList, now)
    local entries = {}
    for _, group in ipairs(groupList) do
        local rare = ns.Rares[group.npcID]
        local status = ns.RareStatus(rare, ns.PeekState(group.npcID), now)
        entries[#entries + 1] = {
            group = group, rare = rare, status = status,
            order = STATUS_ORDER[status and status.kind or "none"],
            level = rare.level and rare.level[1] or 0,
            name = ns.GetName(group.npcID),
        }
    end
    table.sort(entries, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        if a.level ~= b.level then return a.level < b.level end
        return a.name < b.name
    end)
    return entries
end

-- Short status shown at the right of a row.
local function StatusText(status)
    if not status then return "" end
    if status.kind == "dead" then return "|cffff6666" .. ns.FormatTimer(status.from) .. "|r" end
    if status.kind == "window" then return "|cffffd200" .. L["Up?"] .. "|r" end
    return "|cff33ff66" .. L["Seen"] .. "|r"
end

-- Rows ---------------------------------------------------------------------------
local function RowOnEnter(row)
    if map then ns.Overlay.Highlight(map, row.group) end
    ns.PingRare(row.group)
    ns.Tooltip.ShowRare(row, row.group.npcID)
end

local function RowOnLeave()
    GameTooltip:Hide()
    ns.RestoreFocus()  -- back to the rare open in the detail panel, if any
end

local function RowOnClick(row)
    local group = row.group
    if IsShiftKeyDown() and map then
        ns.SetWaypoint(map:GetMapID(), group.primary.x, group.primary.y)
    else
        ns.DetailPanel.Show(group.npcID)
    end
end

local function GetRow(index)
    if rows[index] then return rows[index] end
    local row = CreateFrame("Button", nil, frame.Content)
    row:SetHeight(ROW_H)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row.Status = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.Status:SetPoint("RIGHT", -4, 0)
    row.Level = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.Level:SetPoint("RIGHT", -52, 0)
    row.Name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.Name:SetPoint("LEFT", 4, 0)
    row.Name:SetPoint("RIGHT", row.Level, "LEFT", -4, 0)
    row.Name:SetJustifyH("LEFT")
    row.Name:SetWordWrap(false)
    row:RegisterForClicks("LeftButtonUp")
    row:SetScript("OnEnter", RowOnEnter)
    row:SetScript("OnLeave", RowOnLeave)
    row:SetScript("OnClick", RowOnClick)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_H)
    rows[index] = row
    return row
end

-- Frames -------------------------------------------------------------------------
-- Tab and panel live in `holder`, a map-sized frame: addons that read the map's edge off its
-- direct children to stack their own tabs keep their place, so tabs never swap around.
local holder

local function SetOpen(open)
    ns.db.listCollapsed = not open
    PlaySound(open and SOUNDKIT.IG_CHARACTER_INFO_OPEN or SOUNDKIT.IG_CHARACTER_INFO_CLOSE)
    RareList.Update()
end

-- Leatrix Maps' simple map frame hides the game's border and draws its own around the map and
-- the quest log: a 22 high title bar, a black frame 1 outside the map and a gold border 5
-- past that.
local LEATRIX_TITLE, LEATRIX_OUT = 22, 1 + 5
local leatrixEdge

local function LeatrixFrameOn()
    local db = _G.LeaMapsDB
    local loaded = C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Leatrix_Maps")
    return loaded and type(db) == "table" and db.SimpleMapFrame ~= "Off"
end

-- The frame the player sees around the map: tabs and panels hang off its right edge.
local function MapEdge()
    if LeatrixFrameOn() then
        leatrixEdge = leatrixEdge or CreateFrame("Frame", nil, holder)
        local map = WorldMapFrame.ScrollContainer
        local questWidth = QuestMapFrame and QuestMapFrame:IsShown()
            and WorldMapFrame.questLogWidth or 0
        leatrixEdge:ClearAllPoints()
        leatrixEdge:SetPoint("TOPLEFT", map, "TOPLEFT", -LEATRIX_OUT, LEATRIX_TITLE + 1)
        leatrixEdge:SetPoint("BOTTOMRIGHT", map, "BOTTOMRIGHT", questWidth + LEATRIX_OUT, -LEATRIX_OUT)
        return leatrixEdge
    end
    local border = WorldMapFrame.BorderFrame
    if border and border:IsShown() then return border end
    return WorldMapFrame
end

-- The game's side tab (as on the character frame), the one other addons use on the map's
-- edge too; a plain icon button where the client lacks the template.
local function CreateTab(parent)
    local onClick = function() SetOpen(true) end
    local ok, button = pcall(CreateFrame, "Frame", "RareCodexMapTab", parent,
        "LargeSideTabButtonTemplate")
    if ok and button and button.Icon and button.SetCustomOnMouseUpHandler then
        button.Icon:SetTexture(TAB_ICON)
        button.tooltipText = L["Rares of this map"]
        button:SetCustomOnMouseUpHandler(onClick)
        if button.SetChecked then button:SetChecked(false) end  -- it only ever opens
        button:EnableMouse(true)
        return button
    end
    button = CreateFrame("Button", "RareCodexMapTab", parent)
    button:SetSize(40, 40)
    button:SetNormalTexture(TAB_ICON)
    button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    button:SetScript("OnClick", onClick)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(L["Rares of this map"])
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", GameTooltip_Hide)
    return button
end

local function Create()
    holder = CreateFrame("Frame", nil, WorldMapFrame)
    holder:SetAllPoints(WorldMapFrame)
    holder:SetFrameLevel(WorldMapFrame:GetFrameLevel() + 10)

    tab = CreateTab(holder)
    tab:SetScript("OnHide", function(self)
        if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
    end)

    frame = CreateFrame("Frame", nil, holder, "BackdropTemplate")
    frame:SetWidth(WIDTH)
    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 14, insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    frame:SetBackdropColor(0.05, 0.05, 0.05, 0.92)
    frame:SetBackdropBorderColor(0.7, 0.7, 0.7, 1)
    frame:EnableMouse(true)

    frame.Title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.Title:SetPoint("TOPLEFT", INSET + 4, -INSET - 6)
    frame.Close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    frame.Close:SetPoint("TOPRIGHT", 0, 0)
    frame.Close:SetScript("OnClick", function() SetOpen(false) end)

    frame.Scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    frame.Scroll.scrollBarHideable = true  -- the template then hides it when nothing scrolls
    frame.Scroll:SetPoint("TOPLEFT", INSET, -HEADER_H)
    frame.Content = CreateFrame("Frame", nil, frame.Scroll)
    frame.Content:SetSize(1, 1)
    frame.Scroll:SetScrollChild(frame.Content)
end

-- Other addons' side tabs and panels on the map's edge -------------------------------
-- The game keeps no list of side tabs, so what hangs off the map's right edge is read off
-- the screen, whoever made it, and we go past it. Frames are watched so we move again when
-- one of them shows or hides (another addon's panel opening, for instance).
local EDGE_SLACK = 12
local watched = setmetatable({}, { __mode = "k" })
local relayoutPending = false

local function RelayoutSoon()
    if relayoutPending then return end
    relayoutPending = true
    C_Timer.After(0, function()
        relayoutPending = false
        RareList.Update()
    end)
end

local function Rect(f, scale)
    local left, right, top, bottom = f:GetLeft(), f:GetRight(), f:GetTop(), f:GetBottom()
    if not (left and right and top and bottom) then return nil end
    local k = f:GetEffectiveScale() / scale
    return left * k, right * k, top * k, bottom * k
end

-- Visible frames hanging off the edge (other addons' side tabs and panels), as rectangles in
-- the edge's coordinates. Watched so we move again when one of them shows or hides.
local function FramesBeside(edge)
    local scale = edge:GetEffectiveScale()
    local _, edgeRight = Rect(edge, scale)
    local found = {}
    if not edgeRight then return found, scale end
    for _, parent in ipairs({ QuestMapFrame or false, WorldMapFrame, WorldMapFrame.BorderFrame or false }) do
        for _, child in ipairs(parent and { parent:GetChildren() } or {}) do
            if child ~= holder then
                if not watched[child] and child.HookScript then
                    watched[child] = true
                    child:HookScript("OnShow", RelayoutSoon)
                    child:HookScript("OnHide", RelayoutSoon)
                end
                local left, right, top, bottom
                if child:IsVisible() then left, right, top, bottom = Rect(child, scale) end
                if left and left >= edgeRight - EDGE_SLACK and right > edgeRight then
                    found[#found + 1] = { frame = child, right = right - edgeRight, top = top, bottom = bottom }
                end
            end
        end
    end
    return found, scale
end

-- The tab goes under the lowest side tab already on the edge (shorter than half the map, so
-- a panel standing there is not taken for one), or in the first slot. The panel opens beside
-- the map, past whatever stands on the edge.
local function Anchor(open)
    local edge = MapEdge()
    local frames, scale = FramesBeside(edge)
    local _, _, edgeTop, edgeBottom = Rect(edge, scale)
    if not edgeTop then return end
    if open then
        local reach = 0
        for _, f in ipairs(frames) do reach = math.max(reach, f.right) end
        local x = reach > 0 and reach + PANEL_GAP or PANEL_GAP
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", edge, "TOPRIGHT", x, 0)
        frame:SetPoint("BOTTOMLEFT", edge, "BOTTOMRIGHT", x, 0)
        return
    end
    local lowest
    for _, f in ipairs(frames) do
        local isTab = f.top - f.bottom < (edgeTop - edgeBottom) / 2
            and f.top <= edgeTop + EDGE_SLACK and f.bottom >= edgeBottom - EDGE_SLACK
        if isTab and (not lowest or f.bottom < lowest.bottom) then lowest = f end
    end
    tab:ClearAllPoints()
    if lowest then
        tab:SetPoint("TOPLEFT", lowest.frame, "BOTTOMLEFT", 0, -TAB_GAP)
        return
    end
    -- First slot, past any panel standing there (another addon's, open).
    local slotTop = edgeTop - TAB_TOP
    local slotBottom = slotTop - tab:GetHeight()
    local reach = 0
    for _, f in ipairs(frames) do
        if f.top > slotBottom and f.bottom < slotTop then reach = math.max(reach, f.right) end
    end
    tab:SetPoint("TOPLEFT", edge, "TOPRIGHT", reach > 0 and reach + PANEL_GAP or 0, -TAB_TOP)
end
-- Fits the rows to the panel; the scroll bar only shows when they do not all fit.
local function Layout(count)
    local listHeight = frame:GetHeight() - HEADER_H - INSET
    local scrolls = count * ROW_H > listHeight
    local rowWidth = WIDTH - 2 * INSET - (scrolls and SCROLLBAR_W or 0)
    frame.Scroll:SetPoint("BOTTOMRIGHT", -INSET - (scrolls and SCROLLBAR_W or 0), INSET)
    frame.Scroll.ScrollBar:SetShown(scrolls)
    if not scrolls then frame.Scroll:SetVerticalScroll(0) end
    frame.Content:SetSize(rowWidth, math.max(1, count * ROW_H))
    for _, row in ipairs(rows) do row:SetWidth(rowWidth) end
end

--- Redraws the tab or panel from the groups last shown on the map (status, order, size).
--- Maximized, the map fills the screen and anything beside it would be off-screen.
function RareList.Update()
    if not frame then return end
    local maximized = WorldMapFrame.IsMaximized and WorldMapFrame:IsMaximized()
    local enabled = ns.db.showList and #groups > 0 and not maximized
    local open = enabled and not ns.db.listCollapsed
    tab:SetShown(enabled and not open)
    frame:SetShown(open)
    if not enabled then return end
    Anchor(open)
    if not open then return end

    frame.Title:SetText(L["Rares (%d)"]:format(#groups))
    local entries = RareList.SortedEntries(groups, time())
    for i, entry in ipairs(entries) do
        local row = GetRow(i)
        row.group = entry.group
        local icon = ns.CreatureTypeIcon(entry.rare, 14)
        local color = entry.rare.elite and "|cffffd200" or "|cff66ccff"
        row.Name:SetText((icon and (icon .. " ") or "") .. color .. entry.name .. "|r")
        row.Level:SetText(ns.FormatColoredLevel(entry.rare))
        row.Status:SetText(StatusText(entry.status))
        row:Show()
    end
    for i = #entries + 1, #rows do rows[i]:Hide() end
    Layout(#entries)
end
--- Called by the map data provider whenever the shown map or its pins change.
function RareList.SetGroups(canvas, groupList)
    map, groups = canvas, groupList or {}
    if not frame and #groups > 0 then Create() end
    RareList.Update()
end