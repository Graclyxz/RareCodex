-- Contribute: lets players share the rares they recorded (RareCodexDB.unknown) so they can be
-- added to the database for everyone. Addons cannot reach the internet, so the window walks
-- the player through it: open the submission page, copy the data, paste it there.
-- A clickable chat message opens the window.
local addonName, ns = ...
local L = ns.L

local Contribute = {}
ns.Contribute = Contribute

local SUBMIT_URL = "https://github.com/Graclyxz/RareCodex/issues/new?template=rare-data.yml"
local LINK = "addon:" .. addonName .. ":contribute"
local MERGE_DISTANCE = 25     -- yards; closer sightings are the same spawn point
local LOGIN_REMINDER_DELAY = 10

local frame

-- Data -----------------------------------------------------------------------------
-- Map sighting -> world coordinates in database order (see Coords.WorldVector).
local function ToWorld(sighting)
    local instanceID, pos = C_Map.GetWorldPosFromMapPos(sighting.mapID,
        CreateVector2D(sighting.x, sighting.y))
    if not instanceID or not pos then return end
    local a, b = pos:GetXY()
    if ns.db.axisSwapped then a, b = b, a end
    return instanceID, a, b
end

local function JsonString(value)
    return '"' .. tostring(value):gsub('[%c"\\]', function(c)
        if c == '"' or c == "\\" then return "\\" .. c end
        return ("\\u%04x"):format(c:byte())
    end) .. '"'
end

local function Spawns(record)
    local spawns = {}
    for _, sighting in ipairs(record.sightings) do
        local instanceID, x, y = ToWorld(sighting)
        if instanceID then
            local duplicate = false
            for _, s in ipairs(spawns) do
                if s[1] == instanceID and (s[2] - x) ^ 2 + (s[3] - y) ^ 2 < MERGE_DISTANCE ^ 2 then
                    duplicate = true
                    break
                end
            end
            if not duplicate then spawns[#spawns + 1] = { instanceID, x, y } end
        end
    end
    return spawns
end

-- Patrol tracks as JSON arrays [instanceID, x1, y1, x2, y2, ...] in world coordinates.
-- Points on another continent than the first one (should not happen) are dropped.
local function Tracks(record)
    local out = {}
    for _, track in ipairs(record.tracks or {}) do
        local instance, coords = nil, {}
        for i = 1, #track.points, 2 do
            local inst, x, y = ToWorld({ mapID = track.mapID, x = track.points[i], y = track.points[i + 1] })
            if inst and (instance == nil or inst == instance) then
                instance = inst
                coords[#coords + 1] = ("%.2f,%.2f"):format(x, y)
            end
        end
        if instance and #coords >= 2 then
            out[#out + 1] = ("[%d,%s]"):format(instance, table.concat(coords, ","))
        end
    end
    return out
end

--- npcIDs of recorded rares, sorted; only those not shared yet unless includeShared.
function Contribute.PendingIDs(includeShared)
    local ids = {}
    for npcID, record in pairs(ns.db.unknown) do
        if includeShared or not record.shared then ids[#ids + 1] = npcID end
    end
    table.sort(ids)
    return ids
end

--- JSON document for the given npcIDs: addon/game metadata plus one object per rare.
--- Nothing that identifies the player is included.
function Contribute.BuildJson(ids)
    local lines = {}
    for _, npcID in ipairs(ids) do
        local record = ns.db.unknown[npcID]
        local spawns = {}
        for _, s in ipairs(Spawns(record)) do
            spawns[#spawns + 1] = ("[%d,%.2f,%.2f]"):format(s[1], s[2], s[3])
        end
        lines[#lines + 1] = ('    {"id":%d,"name":%s,"level":%s,"elite":%s,"spawns":[%s],"tracks":[%s]}'):format(
            npcID, JsonString(record.name or "?"),
            record.level and tostring(record.level) or "null",
            record.elite and "true" or "false",
            table.concat(spawns, ","),
            table.concat(Tracks(record), ","))
    end
    local version = C_AddOns and C_AddOns.GetAddOnMetadata(addonName, "Version") or "?"
    local build = GetBuildInfo and table.concat({ GetBuildInfo() }, " ", 1, 2) or "?"
    local locale = GetLocale and GetLocale() or "?"
    return ('{\n  "addon":%s,\n  "game":%s,\n  "locale":%s,\n  "rares":[\n%s\n  ]\n}\n'):format(
        JsonString(version), JsonString(build), JsonString(locale), table.concat(lines, ",\n"))
end

-- Window -----------------------------------------------------------------------------
local function StepLabel(parent, number, text, y)
    local badge = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    badge:SetPoint("TOPLEFT", 16, y)
    badge:SetText(number .. ".")
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("TOPLEFT", 40, y)
    label:SetPoint("RIGHT", -16, 0)
    label:SetJustifyH("LEFT")
    label:SetText(text)
    return label
end

local function SelectAll(edit)
    edit:SetFocus()
    edit:HighlightText()
end

local function Create()
    frame = CreateFrame("Frame", "RareCodexContributeFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(560, 470)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    table.insert(UISpecialFrames, "RareCodexContributeFrame")

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", 0, -5)
    title:SetText(L["Help improve RareCodex"])

    frame.Intro = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.Intro:SetPoint("TOPLEFT", 16, -34)
    frame.Intro:SetPoint("RIGHT", -16, 0)
    frame.Intro:SetJustifyH("LEFT")

    -- Step 1: the submission page.
    StepLabel(frame, 1, L["Open this page in your browser (copy it with Ctrl+C). It needs a free GitHub account."], -84)
    local url = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    url:SetPoint("TOPLEFT", 46, -122)
    url:SetSize(400, 22)
    url:SetAutoFocus(false)
    url:SetScript("OnTextChanged", function(self, userInput)
        if userInput then self:SetText(SUBMIT_URL) end  -- read-only; ignore our own SetText
    end)
    url:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    url:SetScript("OnEscapePressed", function() frame:Hide() end)
    url:SetText(SUBMIT_URL)
    local copyUrl = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    copyUrl:SetPoint("LEFT", url, "RIGHT", 8, 0)
    copyUrl:SetSize(80, 22)
    copyUrl:SetText(L["Select"])
    copyUrl:SetScript("OnClick", function() SelectAll(url) end)

    -- Step 2: the data.
    StepLabel(frame, 2, L["Copy your data (select it and press Ctrl+C)."], -158)
    local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 46, -184)
    scroll:SetPoint("BOTTOMRIGHT", -40, 150)
    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetColorTexture(0, 0, 0, 0.5)
    bg:SetPoint("TOPLEFT", scroll, -4, 4)
    bg:SetPoint("BOTTOMRIGHT", scroll, 4, -4)
    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetFontObject(ChatFontNormal)
    edit:SetWidth(460)
    edit:SetScript("OnEscapePressed", function() frame:Hide() end)
    edit:SetScript("OnTextChanged", function(self, userInput)
        if userInput then self:SetText(frame.json or "") end  -- read-only
    end)
    scroll:SetScrollChild(edit)
    frame.Edit = edit
    local copyData = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    copyData:SetPoint("TOPRIGHT", scroll, "BOTTOMRIGHT", 4, -8)
    copyData:SetSize(110, 22)
    copyData:SetText(L["Select all"])
    copyData:SetScript("OnClick", function() SelectAll(edit) end)

    -- Step 3: paste and send.
    StepLabel(frame, 3, L["On the page, paste the data into the \"Data\" field and press \"Create\". That's it, thank you!"], -362)

    local done = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    done:SetPoint("BOTTOMRIGHT", -16, 14)
    done:SetSize(170, 24)
    done:SetText(L["Done, I sent it"])
    done:SetScript("OnClick", function()
        for _, npcID in ipairs(frame.ids or {}) do ns.db.unknown[npcID].shared = true end
        ns.Print(L["Thank you for helping improve RareCodex!"])
        frame:Hide()
    end)
    frame.Done = done
    local close = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    close:SetPoint("RIGHT", done, "LEFT", -8, 0)
    close:SetSize(100, 24)
    close:SetText(CLOSE)
    close:SetScript("OnClick", function() frame:Hide() end)
end

function Contribute.Show()
    if not frame then Create() end
    local ids = Contribute.PendingIDs(false)
    local pending = #ids
    if pending == 0 then ids = Contribute.PendingIDs(true) end
    frame.ids = ids
    if #ids == 0 then
        frame.Intro:SetText(L["No rares recorded yet. They are saved when a rare missing from the database appears on your minimap or you target it."])
    elseif pending == 0 then
        frame.Intro:SetText(L["You already shared all your recorded rares (%d). You can send them again if needed."]:format(#ids))
    else
        frame.Intro:SetText(L["You discovered %d rares that are not in the database yet. Sharing them adds them to RareCodex for everyone."]:format(pending))
    end
    frame.json = #ids > 0 and Contribute.BuildJson(ids) or ""
    frame.Edit:SetText(frame.json)
    frame.Done:SetEnabled(#ids > 0)
    frame:Show()
end

-- Chat reminder ------------------------------------------------------------------------
function Contribute.ChatLink()
    return ("|cff33ccff|H%s|h[%s]|h|r"):format(LINK, L["Help improve RareCodex"])
end

local function Remind(message)
    if ns.db.contributeReminders then
        ns.Print(message .. " " .. Contribute.ChatLink())
    end
end

--- Called by Detection the first time a rare missing from the database is recorded.
function Contribute.OnNewRare(name)
    Remind(L["New rare recorded: |cffffd200%s|r."]:format(name or "?"))
end

ns.On("PLAYER_LOGIN", function()
    C_Timer.After(LOGIN_REMINDER_DELAY, function()
        local pending = #Contribute.PendingIDs(false)
        if pending > 0 then
            Remind(L["You have %d recorded rares that are not in the database yet."]:format(pending))
        end
    end)
end)

-- Clicking the link: newer clients fire EventRegistry "SetItemRef" for addon: links; older
-- ones only call SetItemRef. Both are hooked; the timestamp keeps one click from firing twice.
local lastClick
local function OnLinkClicked(link)
    if type(link) ~= "string" or link:sub(1, #LINK) ~= LINK then return end
    local now = GetTime()
    if lastClick == now then return end
    lastClick = now
    Contribute.Show()
end

if EventRegistry and EventRegistry.RegisterCallback then
    EventRegistry:RegisterCallback("SetItemRef", function(_, link) OnLinkClicked(link) end, Contribute)
end
if SetItemRef then
    hooksecurefunc("SetItemRef", function(link) OnLinkClicked(link) end)
end
