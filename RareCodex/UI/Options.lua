-- Options: panel under Game Menu > Options > AddOns > RareCodex.
local addonName, ns = ...

local CHECKBOXES = {
    { section = "Show rare pins on" },
    { label = "Zone maps", get = function() return ns.db.show.zone end,
      set = function(v) ns.db.show.zone = v end },
    { label = "Continent maps (pins only, no patrol lines)", get = function() return ns.db.show.continent end,
      set = function(v) ns.db.show.continent = v end },
    { label = "World map (pins only, no patrol lines)", get = function() return ns.db.show.world end,
      set = function(v) ns.db.show.world = v end },
    { section = "Display" },
    { label = "Patrol routes and wander areas on zone maps", get = function() return ns.db.showPaths end,
      set = function(v) ns.db.showPaths = v end },    { section = "Alerts" },
    { label = "Sound and on-screen warning when a rare appears", get = function() return ns.db.alerts end,
      set = function(v) ns.db.alerts = v end },
}

local category
local checkboxes = {}

local function CreatePanel()
    local panel = CreateFrame("Frame")
    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText(addonName)

    local y = -52
    for _, def in ipairs(CHECKBOXES) do
        if def.section then
            local header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            header:SetPoint("TOPLEFT", 16, y - 8)
            header:SetText(def.section)
            y = y - 32
        else
            local check = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
            check:SetPoint("TOPLEFT", 24, y)
            local label = check:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            label:SetPoint("LEFT", check, "RIGHT", 4, 0)
            label:SetText(def.label)
            check:SetScript("OnClick", function(self)
                def.set(self:GetChecked())
                ns.RefreshMap()
            end)
            check.def = def
            checkboxes[#checkboxes + 1] = check
            y = y - 28
        end
    end

    -- Saved values may change through slash commands, so sync every time the panel opens.
    panel:SetScript("OnShow", function()
        for _, check in ipairs(checkboxes) do check:SetChecked(check.def.get()) end
    end)
    return panel
end

function ns.OpenOptions()
    if category then
        Settings.OpenToCategory(category:GetID())
    end
end

ns.On("PLAYER_LOGIN", function()
    if not Settings or not Settings.RegisterCanvasLayoutCategory then return end
    category = Settings.RegisterCanvasLayoutCategory(CreatePanel(), addonName)
    Settings.RegisterAddOnCategory(category)
end)
