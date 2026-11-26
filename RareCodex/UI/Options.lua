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
    { section = L["Detail panel"] },
    { slider = L["Size (Ctrl + mouse wheel over the panel)"], min = 0.7, max = 1.4, step = 0.05,
      get = function() return ns.db.panel.scale end,
      set = function(v) ns.DetailPanel.SetScale(v) end },
    { button = L["Reset position and size"], onClick = function() ns.DetailPanel.ResetLayout() end },
    { section = L["Alerts"] },
    Check(L["Sound and on-screen warning when a rare appears"], Setting("alerts")),
    { button = L["Reset alert position"], onClick = function() ns.AlertToast.ResetPosition() end },
    { section = L["Rares recorded in game"] },
    Check(L["Chat reminder to share rares that are not in the database"], Setting("contributeReminders")),
    { button = L["Share recorded rares"], onClick = function() ns.Contribute.Show() end },
}

local category
local checkboxes, sliders = {}, {}

-- A plain horizontal slider with the classic textures (no template needed).
local function CreateSlider(parent, item)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    local slider = CreateFrame("Slider", nil, parent, "BackdropTemplate")
    slider:SetOrientation("HORIZONTAL")
    slider:SetSize(200, 16)
    slider:SetHitRectInsets(0, 0, -6, -6)
    slider:SetBackdrop({
        bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
        edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
        tile = true, tileSize = 8, edgeSize = 8,
        insets = { left = 3, right = 3, top = 6, bottom = 6 },
    })
    slider:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    slider:SetMinMaxValues(item.min, item.max)
    slider:SetValueStep(item.step)
    slider:SetObeyStepOnDrag(true)
    slider.Value = slider:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    slider.Value:SetPoint("LEFT", slider, "RIGHT", 8, 0)
    slider:SetScript("OnValueChanged", function(self, value)
        self.Value:SetText(("%d%%"):format(math.floor(value * 100 + 0.5)))
        if not self.syncing then item.set(value) end
    end)
    slider.label, slider.item = label, item
    label:SetText(item.slider)
    return slider, label
end

local function CreatePanel()
    local panel = CreateFrame("Frame")
    -- The options scroll when they do not fit the window's height.
    local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, -4)
    scroll:SetPoint("BOTTOMRIGHT", -28, 4)
    scroll.scrollBarHideable = true
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(600, 1)
    scroll:SetScrollChild(content)

    local title = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -12)
    title:SetText(addonName)

    local y = -48
    for _, item in ipairs(ITEMS) do
        if item.section then
            local header = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            header:SetPoint("TOPLEFT", 16, y - 8)
            header:SetText(item.section)
            y = y - 32
        elseif item.slider then
            local slider, label = CreateSlider(content, item)
            label:SetPoint("TOPLEFT", 28, y)
            slider:SetPoint("TOPLEFT", 28, y - 20)
            sliders[#sliders + 1] = slider
            y = y - 50
        elseif item.button then
            local button = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
            button:SetPoint("TOPLEFT", 24, y)
            button:SetSize(200, 22)
            button:SetText(item.button)
            button:SetScript("OnClick", item.onClick)
            y = y - 30
        else
            local check = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
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

    content:SetHeight(-y + 16)

    -- Saved values may change through slash commands, so sync every time the panel opens.
    panel:SetScript("OnShow", function()
        content:SetWidth(math.max(1, scroll:GetWidth()))
        for _, check in ipairs(checkboxes) do check:SetChecked(check.item.get()) end
        for _, slider in ipairs(sliders) do
            slider.syncing = true
            slider:SetValue(slider.item.get())
            slider.syncing = false
        end
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
