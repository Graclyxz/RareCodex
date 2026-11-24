-- RareList: list of the rares on the world map being viewed, in the map's bottom left corner.
-- Its title folds it; hovering a row highlights the rare's pin and route, clicking opens it.
local _, ns = ...
local L = ns.L

local RareList = {}
ns.RareList = RareList

local WIDTH = 240
local ROW_H = 20
local HEADER_H = 22
local INSET = 4
local SCROLLBAR_W = 22
local MAX_HEIGHT_MARGIN = 80   -- room left above the list inside the map
local EXPANDED, COLLAPSED = "Interface\\Buttons\\UI-MinusButton-Up", "Interface\\Buttons\\UI-PlusButton-Up"

-- Lower sorts first: rares that may be up before the ones known to be dead.
local STATUS_ORDER = { seen = 1, window = 2, none = 3, dead = 4 }

local map, groups = nil, {}
local frame
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
    ns.Tooltip.ShowRare(row, row.group.npcID)
end

local function RowOnLeave()
    GameTooltip:Hide()
    if map then ns.Overlay.Highlight(map, nil) end
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

-- Frame --------------------------------------------------------------------------
local function Create()
    local container = WorldMapFrame.ScrollContainer
    frame = CreateFrame("Frame", nil, WorldMapFrame, "BackdropTemplate")
    frame:SetWidth(WIDTH)
    -- Bottom left: the map's own buttons and most addons use the top corners.
    frame:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", 6, 6)
    -- Above the map canvas and its pins, below the map's own dropdowns and dialogs.
    frame:SetFrameLevel(container:GetFrameLevel() + 1000)
    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame:SetBackdropColor(0, 0, 0, 0.8)
    frame:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
    frame:EnableMouse(true)  -- clicks on the list must not reach the map

    -- Title bar: click to fold or unfold the list.
    local header = CreateFrame("Button", nil, frame)
    header:SetPoint("TOPLEFT", INSET, -INSET)
    header:SetPoint("TOPRIGHT", -INSET, -INSET)
    header:SetHeight(HEADER_H - INSET)
    header.Arrow = header:CreateTexture(nil, "OVERLAY")
    header.Arrow:SetSize(14, 14)
    header.Arrow:SetPoint("LEFT", 2, 0)
    header.Title = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    header.Title:SetPoint("LEFT", header.Arrow, "RIGHT", 4, 0)
    header:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    header:SetScript("OnClick", function()
        ns.db.listCollapsed = not ns.db.listCollapsed
        RareList.Update()
    end)
    frame.Header = header

    frame.Scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    frame.Scroll.scrollBarHideable = true  -- the template then hides it when nothing scrolls
    frame.Scroll:SetPoint("TOPLEFT", INSET, -HEADER_H)
    frame.Content = CreateFrame("Frame", nil, frame.Scroll)
    frame.Content:SetSize(1, 1)
    frame.Scroll:SetScrollChild(frame.Content)
end

-- Fits the list to its rows; the scroll bar only shows when they do not all fit.
local function Layout(count)
    local maxHeight = WorldMapFrame.ScrollContainer:GetHeight() - MAX_HEIGHT_MARGIN
    local listHeight = math.min(count * ROW_H, maxHeight - HEADER_H - INSET)
    local scrolls = count * ROW_H > listHeight
    local rowWidth = WIDTH - 2 * INSET - (scrolls and SCROLLBAR_W or 0)
    frame.Scroll:SetPoint("BOTTOMRIGHT", -INSET - (scrolls and SCROLLBAR_W or 0), INSET)
    frame.Scroll.ScrollBar:SetShown(scrolls)
    if not scrolls then frame.Scroll:SetVerticalScroll(0) end
    frame.Content:SetSize(rowWidth, math.max(1, count * ROW_H))
    for _, row in ipairs(rows) do row:SetWidth(rowWidth) end
    frame:SetHeight(HEADER_H + listHeight + INSET)
end

--- Redraws the list from the groups last shown on the map (status, order, size).
function RareList.Update()
    if not frame then return end
    frame:SetShown(ns.db.showList and #groups > 0)
    if not frame:IsShown() then return end

    local collapsed = ns.db.listCollapsed
    frame.Header.Title:SetText(L["Rares (%d)"]:format(#groups))
    frame.Header.Arrow:SetTexture(collapsed and COLLAPSED or EXPANDED)
    frame.Scroll:SetShown(not collapsed)
    if collapsed then
        frame:SetHeight(HEADER_H + INSET)
        return
    end

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
