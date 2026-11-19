-- Overlay: draws patrol paths and wander areas on the world map canvas.
local _, ns = ...

local Overlay = {}
ns.Overlay = Overlay

local BASE_THICKNESS = 2.5
local HIGHLIGHT_THICKNESS = 4
local PATH_COLOR = { 1.0, 0.55, 0.1, 0.85 }
local WANDER_COLOR = { 1.0, 0.85, 0.2, 0.6 }
local DIM_ALPHA = 0.25

local frame
local pool, active = {}, {}
local linesByEntry = {}
local highlighted

local function AcquireLine()
    local line = table.remove(pool) or frame:CreateLine(nil, "ARTWORK")
    line:Show()
    active[#active + 1] = line
    return line
end

local function CanvasThickness(map, base)
    return base / math.max(map:GetCanvasScale(), 0.01)
end

local function ApplyStyle(line, color, alpha, thickness)
    line:SetColorTexture(color[1], color[2], color[3], alpha or color[4])
    line:SetThickness(thickness)
end

function Overlay.Clear()
    for _, line in ipairs(active) do
        line:Hide()
        pool[#pool + 1] = line
    end
    wipe(active)
    wipe(linesByEntry)
    highlighted = nil
end

local function DrawShape(entry, points, closed, color, map)
    local width, height = frame:GetSize()
    local lines = {}
    local count = #points / 2
    local segments = closed and count or count - 1
    for i = 1, segments do
        local j = (i % count) + 1
        local line = AcquireLine()
        line:SetStartPoint("TOPLEFT", frame, points[2 * i - 1] * width, -points[2 * i] * height)
        line:SetEndPoint("TOPLEFT", frame, points[2 * j - 1] * width, -points[2 * j] * height)
        ApplyStyle(line, color, nil, CanvasThickness(map, BASE_THICKNESS))
        line.color = color
        lines[#lines + 1] = line
    end
    linesByEntry[entry] = lines
end

function Overlay.Draw(map, uiMapID, entries)
    Overlay.Clear()
    if not ns.db.showPaths then return end
    if not frame then
        frame = CreateFrame("Frame", nil, map:GetCanvas())
        frame:SetAllPoints()
    end
    -- Above the map tiles but below POI and rare pins; the default child level sits
    -- underneath the map texture and the lines would be invisible.
    local ok, level = pcall(function()
        return map:GetPinFrameLevelsManager():GetValidFrameLevel("PIN_FRAME_LEVEL_AREA_POI")
    end)
    frame:SetFrameLevel(ok and level and level - 1 or map:GetCanvas():GetFrameLevel() + 100)
    for _, entry in ipairs(entries) do
        local points, closed = ns.Coords.ShapeForSpawn(entry.spawn, uiMapID)
        if #points >= 4 then
            local color = entry.spawn.path and PATH_COLOR or WANDER_COLOR
            DrawShape(entry, points, closed, color, map)
        end
    end
end

function Overlay.UpdateThickness(map)
    for entry, lines in pairs(linesByEntry) do
        local base = entry == highlighted and HIGHLIGHT_THICKNESS or BASE_THICKNESS
        for _, line in ipairs(lines) do
            line:SetThickness(CanvasThickness(map, base))
        end
    end
end

--- Emphasize one entry's shape and dim the rest; pass nil to reset.
function Overlay.Highlight(map, target)
    highlighted = target
    for entry, lines in pairs(linesByEntry) do
        local isTarget = entry == target
        local alpha = (target == nil or isTarget) and nil or DIM_ALPHA
        local base = isTarget and HIGHLIGHT_THICKNESS or BASE_THICKNESS
        for _, line in ipairs(lines) do
            ApplyStyle(line, line.color, alpha, CanvasThickness(map, base))
        end
    end
end
