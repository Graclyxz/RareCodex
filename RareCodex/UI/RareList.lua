-- RareList: list of the rares on the world map being viewed, on top of the map's left side.
-- Hovering a row highlights the rare's pin and route; clicking opens its details.
local _, ns = ...
local L = ns.L

local RareList = {}
ns.RareList = RareList

local WIDTH = 240
local ROW_H = 20
local HEADER_H = 24
local MAX_HEIGHT_MARGIN = 70   -- room left below the list inside the map
local TOGGLE_SIZE = 28
local ICON = "Interface\\Icons\\INV_Misc_Book_09"

-- Lower sorts first: rares that may be up before the ones known to be dead.
local STATUS_ORDER = { seen = 1, window = 2, none = 3, dead = 4 }

local map, groups = nil, {}
local toggle, frame
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

local function RowOnClick(row, button)
    if button ~= "LeftButton" then return end
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
    row:SetSize(WIDTH - 34, ROW_H)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row.Name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.Name:SetPoint("LEFT", 4, 0)
    row.Name:SetJustifyH("LEFT")
    row.Name:SetWordWrap(false)
    row.Status = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.Status:SetPoint("RIGHT", -4, 0)
    row.Level = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.Level:SetPoint("RIGHT", -52, 0)
    row.Name:SetPoint("RIGHT", row.Level, "LEFT", -4, 0)
    row:RegisterForClicks("LeftButtonUp")
    row:SetScript("OnEnter", RowOnEnter)
    row:SetScript("OnLeave", RowOnLeave)
    row:SetScript("OnClick", RowOnClick)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_H)
    rows[index] = row
    return row
end

-- Frames -------------------------------------------------------------------------
local function Create()
    local container = WorldMapFrame.ScrollContainer
    -- Above the map canvas and its pins, below the map's own dropdowns and dialogs.
    local level = container:GetFrameLevel() + 1000

    toggle = CreateFrame("Button", nil, WorldMapFrame)
    toggle:SetSize(TOGGLE_SIZE, TOGGLE_SIZE)
    toggle:SetPoint("TOPLEFT", container, "TOPLEFT", 6, -6)
    toggle:SetFrameLevel(level)
    toggle:SetNormalTexture(ICON)
    toggle:SetPushedTexture(ICON)
    toggle:GetPushedTexture():SetVertexColor(0.7, 0.7, 0.7)
    toggle:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    toggle:SetScript("OnClick", function()
        ns.db.showList = not ns.db.showList
        RareList.Update()
    end)
    toggle:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("RareCodex")
        GameTooltip:AddLine(L["Show or hide the list of rares on this map"], 1, 1, 1, true)
        GameTooltip:Show()
    end)
    toggle:SetScript("OnLeave", function() GameTooltip:Hide() end)

    frame = CreateFrame("Frame", nil, WorldMapFrame, "BackdropTemplate")
    frame:SetWidth(WIDTH)
    frame:SetPoint("TOPLEFT", toggle, "BOTTOMLEFT", 0, -4)
    frame:SetFrameLevel(level)
    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame:SetBackdropColor(0, 0, 0, 0.8)
    frame:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
    frame:EnableMouse(true)  -- clicks on the list must not reach the map

    frame.Title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.Title:SetPoint("TOPLEFT", 8, -7)

    frame.Scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    frame.Scroll:SetPoint("TOPLEFT", 4, -HEADER_H)
    frame.Scroll:SetPoint("BOTTOMRIGHT", -26, 6)
    frame.Content = CreateFrame("Frame", nil, frame.Scroll)
    frame.Content:SetSize(WIDTH - 34, 1)
    frame.Scroll:SetScrollChild(frame.Content)
end

--- Redraws the list from the groups last shown on the map (status, order, size).
function RareList.Update()
    if not frame then return end
    local visible = #groups > 0
    toggle:SetShown(visible)
    frame:SetShown(visible and ns.db.showList)
    if not frame:IsShown() then return end

    local entries = RareList.SortedEntries(groups, time())
    frame.Title:SetText(L["Rares (%d)"]:format(#entries))
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
    frame.Content:SetHeight(math.max(1, #entries * ROW_H))

    local maxHeight = WorldMapFrame.ScrollContainer:GetHeight() - MAX_HEIGHT_MARGIN
    frame:SetHeight(math.max(HEADER_H + ROW_H + 8,
        math.min(HEADER_H + #entries * ROW_H + 8, maxHeight)))
end

--- Called by the map data provider whenever the shown map or its pins change.
function RareList.SetGroups(canvas, groupList)
    map, groups = canvas, groupList or {}
    if not frame and #groups > 0 then Create() end
    RareList.Update()
end
