-- Options: panel under Game Menu > Options > AddOns > RareCodex.
local addonName, ns = ...
local L = ns.L

local function Setting(key)
    return function() return ns.db[key] end, function(v) ns.db[key] = v end
end

local function ShowSetting(scope)
    return function() return ns.db.show[scope] end, function(v) ns.db.show[scope] = v end
end

local function Check(label, get, set)
    return { label = label, get = get, set = set }
end

local ITEMS = {
    { section = L["Show rare pins on"] },
    Check(L["Zone maps"], ShowSetting("zone")),
    Check(L["Continent maps (pins only, no patrol routes)"], ShowSetting("continent")),
    Check(L["World map (pins only, no patrol routes)"], ShowSetting("world")),
    { section = L["Display"] },
    Check(L["Patrol routes and wander areas on zone maps"], Setting("showPaths")),
    Check(L["Spawn area: outline around all the points where a rare can spawn"], Setting("showSpawnArea")),
    Check(L["Number of possible spawn points on each pin"], Setting("showSpawnCount")),
    Check(L["List of the map's rares beside the world map"], Setting("showList")),
    { section = L["Alerts"] },
    Check(L["Sound and on-screen warning when a rare appears"], Setting("alerts")),
    { section = L["Rares recorded in game"] },
    Check(L["Chat reminder to share rares that are not in the database"], Setting("contributeReminders")),
    { button = L["Share recorded rares"], onClick = function() ns.Contribute.Show() end },
}

local category
local checkboxes = {}

local function CreatePanel()
    local panel = CreateFrame("Frame")
    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText(addonName)

    local y = -52
    for _, item in ipairs(ITEMS) do
        if item.section then
            local header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            header:SetPoint("TOPLEFT", 16, y - 8)
            header:SetText(item.section)
            y = y - 32
        elseif item.button then
            local button = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
            button:SetPoint("TOPLEFT", 24, y)
            button:SetSize(200, 22)
            button:SetText(item.button)
            button:SetScript("OnClick", item.onClick)
            y = y - 30
        else
            local check = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
            check:SetPoint("TOPLEFT", 24, y)
            local label = check:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            label:SetPoint("LEFT", check, "RIGHT", 4, 0)
            label:SetText(item.label)
            check:SetScript("OnClick", function(self)
                item.set(self:GetChecked())
                ns.RefreshMap()
            end)
            check.item = item
            checkboxes[#checkboxes + 1] = check
            y = y - 28
        end
    end

    -- Saved values may change through slash commands, so sync every time the panel opens.
    panel:SetScript("OnShow", function()
        for _, check in ipairs(checkboxes) do check:SetChecked(check.item.get()) end
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
