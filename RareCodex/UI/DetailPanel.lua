-- DetailPanel: full view of one rare - 3D model, abilities, behavior, loot and world drops.
local _, ns = ...
local L = ns.L

local DetailPanel = {}
ns.DetailPanel = DetailPanel

local WIDTH, HEIGHT = 640, 480
local PAD = 12
local CONTENT_TOP = -32
local MODEL_W, MODEL_H = 230, 290
local RIGHT_X = PAD + MODEL_W + 16
local RIGHT_W = WIDTH - RIGHT_X - PAD
local HEADER_GAP = 18     -- header text to the content below it
local SECTION_GAP = 14    -- end of one section to the next header
local ICON = 32
local CELL_W, CELL_H = 42, 50
local LOOT_COLUMNS = 8
local LOOT_MAX = 24
local SPELL_MAX = 9
local WOWHEAD_URL = "https://www.wowhead.com/classic/npc=%d"
local TAB_W, TAB_H = 120, 22
local GEAR_COLUMNS = 8
local GEAR_CELL = 42
local CONTENT_BOTTOM = -(HEIGHT - PAD - 22 - 12)  -- just above the bottom buttons
local ITEM_CLASS_WEAPON, ITEM_CLASS_ARMOR = 2, 4
local GEAR_FILTERS = {
    { key = "all", label = L["All"] },
    { key = ITEM_CLASS_WEAPON, label = L["Weapons"] },
    { key = ITEM_CLASS_ARMOR, label = L["Armor"] },
}

local panel
local currentID
local activeTab, gearFilter = "loot", "all"
local spellButtons, lootButtons, worldButtons, gearButtons = {}, {}, {}, {}

-- Widgets ------------------------------------------------------------------------
local function Header(parent, text)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetText(text)
    return fs
end

local function CreateModel(parent)
    local bg = parent:CreateTexture(nil, "BACKGROUND")
    bg:SetColorTexture(0.05, 0.05, 0.08, 0.9)
    bg:SetPoint("TOPLEFT", PAD, CONTENT_TOP)
    bg:SetSize(MODEL_W, MODEL_H)

    local model = CreateFrame("PlayerModel", nil, parent)
    model:SetAllPoints(bg)
    model:EnableMouse(true)
    model:EnableMouseWheel(true)
    model.facing, model.zoom = 0, 1
    model:SetScript("OnMouseDown", function(self) self.dragX = GetCursorPosition() end)
    model:SetScript("OnMouseUp", function(self) self.dragX = nil end)
    model:SetScript("OnUpdate", function(self)
        if not self.dragX then return end
        local x = GetCursorPosition()
        self.facing = self.facing + (x - self.dragX) * 0.02
        self.dragX = x
        self:SetFacing(self.facing)
    end)
    model:SetScript("OnMouseWheel", function(self, delta)
        self.zoom = math.min(2.5, math.max(0.4, self.zoom + delta * 0.15))
        self:SetCamDistanceScale(1 / self.zoom)
    end)

    local hint = model:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("BOTTOM", 0, 4)
    hint:SetText(L["Drag to rotate, wheel to zoom"])
    return model
end

local function ShowItemTooltip(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetItemByID(self.itemID)
    GameTooltip:AddLine(" ")
    local label = L["Estimated drop chance"]
    if self.personal then
        label = L["Your drop rate"]
    elseif self.observed then
        label = L["Drop rate in WoW Forever"]
    end
    GameTooltip:AddDoubleLine(label, ns.FormatChance(self.chance), 0.7, 0.7, 0.7, 1, 1, 1)
    if self.quest then GameTooltip:AddLine(L["Quest item: only drops while on the quest"], 1, 0.82, 0) end
    if self.looted and self.looted > 0 then
        GameTooltip:AddDoubleLine(L["You looted"], self.looted, 0.7, 0.7, 0.7, 0.4, 1, 0.4)
    end
    GameTooltip:Show()
end

local function ShowSpellTooltip(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetSpellByID(self.spellID)
    GameTooltip:Show()
end

local function HideTooltip() GameTooltip:Hide() end

local function GetSpellButton(i)
    local button = spellButtons[i]
    if not button then
        button = CreateFrame("Button", nil, panel)
        button:SetSize(ICON, ICON)
        button.Icon = button:CreateTexture(nil, "ARTWORK")
        button.Icon:SetAllPoints()
        button:SetScript("OnEnter", ShowSpellTooltip)
        button:SetScript("OnLeave", HideTooltip)
        spellButtons[i] = button
    end
    return button
end

local function GetLootButton(i)
    local button = lootButtons[i]
    if not button then
        button = CreateFrame("Button", nil, panel)
        button:SetSize(ICON, ICON)
        button.Icon = button:CreateTexture(nil, "ARTWORK")
        button.Icon:SetAllPoints()
        button.Border = button:CreateTexture(nil, "OVERLAY")
        button.Border:SetTexture("Interface\\Common\\WhiteIconFrame")
        button.Border:SetAllPoints()
        button.Chance = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        button.Chance:SetPoint("TOP", button, "BOTTOM", 0, -2)
        button.Count = button:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
        button.Count:SetPoint("BOTTOMRIGHT", -1, 1)
        button:SetScript("OnEnter", ShowItemTooltip)
        button:SetScript("OnLeave", HideTooltip)
        button:SetScript("OnClick", function(self)
            local _, link = C_Item.GetItemInfo(self.itemID)
            if link then HandleModifiedItemClick(link) end
        end)
        lootButtons[i] = button
    end
    return button
end

local function ShowWorldTooltip(self)
    local drop = self.drop
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(self.label:GetText())
    GameTooltip:AddLine(L["Random pick from %d items of this quality."]:format(drop.n), 0.7, 0.7, 0.7, true)
    GameTooltip:AddLine(L["The weapons and armor are listed in the Gear tab."], 0.5, 1, 0.5, true)
    GameTooltip:Show()
end

-- Gear ---------------------------------------------------------------------------------
--- Every weapon and armor piece the rare's world drops can give, with its chance per kill.
--- A pool gives each of its items with the same chance (pool chance / item count); an item
--- found in several pools adds them up.
local function GearList(rare)
    local byItem, list = {}, {}
    for _, drop in ipairs(rare.world or {}) do
        local pools = drop.pools or {}
        for i = 1, #pools, 2 do
            local pool = ns.Pools[pools[i]]
            if pool then
                local each = pools[i + 1] / pool[1]
                for j = 2, #pool do
                    local itemID = pool[j]
                    local entry = byItem[itemID]
                    if not entry then
                        entry = { itemID = itemID, chance = 0, quality = drop.q }
                        byItem[itemID] = entry
                        list[#list + 1] = entry
                    end
                    entry.chance = entry.chance + each
                end
            end
        end
    end
    table.sort(list, function(a, b)
        if a.quality ~= b.quality then return a.quality > b.quality end
        if a.chance ~= b.chance then return a.chance > b.chance end
        return a.itemID < b.itemID
    end)
    return list
end
DetailPanel._GearList = GearList  -- exposed for tests/test_lua_panel.py

local function ShowGearTooltip(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetItemByID(self.itemID)
    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine(L["Chance per kill"], ns.FormatChance(self.chance), 0.7, 0.7, 0.7, 1, 1, 1)
    GameTooltip:Show()
end

local function GetGearButton(i)
    local button = gearButtons[i]
    if not button then
        button = CreateFrame("Button", nil, panel.GearContent)
        button:SetSize(ICON, ICON)
        button.Icon = button:CreateTexture(nil, "ARTWORK")
        button.Icon:SetAllPoints()
        button.Border = button:CreateTexture(nil, "OVERLAY")
        button.Border:SetTexture("Interface\\Common\\WhiteIconFrame")
        button.Border:SetAllPoints()
        button:SetScript("OnEnter", ShowGearTooltip)
        button:SetScript("OnLeave", HideTooltip)
        button:SetScript("OnClick", function(self)
            local _, link = C_Item.GetItemInfo(self.itemID)
            if link then HandleModifiedItemClick(link) end
        end)
        gearButtons[i] = button
    end
    return button
end

local function GetWorldButton(i)
    local button = worldButtons[i]
    if not button then
        button = CreateFrame("Button", nil, panel)
        button:SetSize(RIGHT_W, 16)
        button.label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        button.label:SetPoint("LEFT")
        button:SetScript("OnEnter", ShowWorldTooltip)
        button:SetScript("OnLeave", HideTooltip)
        worldButtons[i] = button
    end
    return button
end

StaticPopupDialogs.RARECODEX_URL = {
    text = L["Copy the link (Ctrl+C):"],
    button1 = CLOSE,
    hasEditBox = true,
    editBoxWidth = 320,
    OnShow = function(self, url)
        local editBox = self.EditBox or self.editBox
        editBox:SetText(url)
        editBox:HighlightText()
        editBox:SetFocus()
    end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

local function PrimarySpawnOnMap(npcID)
    local spawn = ns.Rares[npcID].spawns[1]
    local mapID = ns.Coords.ZoneOfSpawn(spawn)
    if not mapID then return end
    local x, y = ns.Coords.WorldToMap(spawn[1], spawn[2], spawn[3], mapID)
    return mapID, x, y
end

local function CreatePanel()
    panel = CreateFrame("Frame", "RareCodexDetailPanel", UIParent, "BasicFrameTemplateWithInset")
    panel:SetSize(WIDTH, HEIGHT)
    panel:SetPoint("CENTER")
    panel:SetFrameStrata("HIGH")
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
    panel:Hide()
    table.insert(UISpecialFrames, "RareCodexDetailPanel")

    panel.Title = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    panel.Title:SetPoint("TOP", 0, -5)

    panel.Model = CreateModel(panel)

    panel.Info = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    panel.Info:SetPoint("TOPLEFT", PAD, CONTENT_TOP - MODEL_H - 10)
    panel.Info:SetWidth(MODEL_W)
    panel.Info:SetJustifyH("LEFT")
    panel.Info:SetSpacing(3)

    panel.AbilitiesHeader = Header(panel, L["Abilities"])
    panel.AbilitiesHeader:SetPoint("TOPLEFT", RIGHT_X, CONTENT_TOP)

    panel.Behavior = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panel.Behavior:SetWidth(RIGHT_W)
    panel.Behavior:SetJustifyH("LEFT")

    panel.LootHeader = Header(panel, "")
    panel.WorldHeader = Header(panel, L["World drops"])

    -- Tabs: the rare's own loot, or the weapons and armor of its world drops.
    local function Tab(key)
        local tab = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
        tab:SetSize(TAB_W, TAB_H)
        tab:SetScript("OnClick", function()
            activeTab = key
            DetailPanel.Refresh()
        end)
        return tab
    end
    panel.TabLoot, panel.TabGear = Tab("loot"), Tab("gear")
    panel.TabLoot:SetText(L["Loot"])

    -- Gear tab: filters and a scrolling grid of item icons.
    panel.GearFilters = {}
    for i, filter in ipairs(GEAR_FILTERS) do
        local button = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
        button:SetSize(90, 20)
        button:SetText(filter.label)
        button:SetScript("OnClick", function()
            gearFilter = filter.key
            DetailPanel.Refresh()
        end)
        button.key = filter.key
        panel.GearFilters[i] = button
    end
    panel.GearScroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    panel.GearContent = CreateFrame("Frame", nil, panel.GearScroll)
    panel.GearContent:SetSize(GEAR_COLUMNS * GEAR_CELL, 1)
    panel.GearScroll:SetScrollChild(panel.GearContent)
    panel.GearEmpty = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    panel.GearEmpty:SetText(L["No weapons or armor of this kind."])

    local buttons = {
        { L["Show on map"], function()
            local mapID = PrimarySpawnOnMap(currentID)
            if mapID then OpenWorldMap(mapID) end
        end },
        { L["Waypoint"], function()
            local mapID, x, y = PrimarySpawnOnMap(currentID)
            if mapID and x then ns.SetWaypoint(mapID, x, y) end
        end },
        { L["Wowhead link"], function()
            StaticPopup_Show("RARECODEX_URL", nil, nil, WOWHEAD_URL:format(currentID))
        end },
    }
    for i, def in ipairs(buttons) do
        local button = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
        button:SetSize(120, 22)
        button:SetPoint("BOTTOMRIGHT", -PAD - (i - 1) * 126, PAD)
        button:SetText(def[1])
        button:SetScript("OnClick", def[2])
    end
end

-- Rendering ----------------------------------------------------------------------
-- Each Render* function lays out one section starting at `top` and returns where the
-- next section starts, so empty sections take no space.
local function QualityColor(quality)
    local r, g, b = C_Item.GetItemQualityColor(quality or 1)
    return r or 1, g or 1, b or 1
end

local function RenderInfo(npcID, rare)
    local state = ns.PeekState(npcID)
    local lines = {
        ns.FormatLevelLine(rare, "|cff66ccff"),
        L["Respawn: %s"]:format(ns.FormatRespawn(rare)),
        L["Spawn points: %d"]:format(#rare.spawns),
    }
    if rare.gold then
        local money = GetMoneyString(rare.gold[1]) .. " - " .. GetMoneyString(rare.gold[2])
        lines[#lines + 1] = L["Money: %s"]:format(money)
    end
    if state and state.lastSeen then
        lines[#lines + 1] = "|cff88ff88" .. L["Last seen %s"]:format(ns.FormatAgo(state.lastSeen)) .. "|r"
    else
        lines[#lines + 1] = "|cffff5555" .. L["Never seen"] .. "|r"
    end
    lines[#lines + 1] = L["Kills: %d"]:format(state and state.kills or 0)
    panel.Info:SetText(table.concat(lines, "\n"))
end

local function RenderSpells(rare, top)
    local shown = 0
    for _, spellID in ipairs(rare.spells) do
        local icon = C_Spell.GetSpellTexture(spellID)
        if icon and shown < SPELL_MAX then
            shown = shown + 1
            local button = GetSpellButton(shown)
            button.spellID = spellID
            button.Icon:SetTexture(icon)
            button:SetPoint("TOPLEFT", RIGHT_X + (shown - 1) * (ICON + 4), top - HEADER_GAP)
            button:Show()
        end
    end
    for i = shown + 1, #spellButtons do spellButtons[i]:Hide() end

    local behavior = {}
    if rare.unknown then
        behavior[#behavior + 1] = L["Recorded in game: no ability or loot data yet."]
    elseif shown == 0 then
        behavior[#behavior + 1] = L["Melee only, no known abilities."]
    end
    if rare.flee then behavior[#behavior + 1] = L["Flees at %d%% health."]:format(rare.flee) end
    local spawn = rare.spawns[1]
    if spawn.path then
        behavior[#behavior + 1] = L["Patrols a fixed route (line on the map)."]
    elseif spawn.wander then
        behavior[#behavior + 1] = L["Wanders within %d yards (shaded area on the map)."]:format(spawn.wander)
    end

    -- Without ability icons the behavior text moves up right under the header.
    local textTop = top - HEADER_GAP - (shown > 0 and ICON + 6 or 0)
    panel.Behavior:ClearAllPoints()
    panel.Behavior:SetPoint("TOPLEFT", RIGHT_X, textTop)
    panel.Behavior:SetText(table.concat(behavior, " "))
    return textTop - panel.Behavior:GetStringHeight() - SECTION_GAP
end

-- Database loot with estimated chances or, for rares recorded in game, the player's own
-- drops with a rate computed from their kills.
local function LootList(npcID, rare)
    if #rare.loot > 0 then return rare.loot, false end
    local state = ns.PeekState(npcID)
    local list = {}
    if state and state.kills > 0 then
        for itemID, count in pairs(state.loot) do
            list[#list + 1] = { itemID, 100 * count / state.kills }
        end
        table.sort(list, function(a, b) return a[2] > b[2] end)
    end
    return list, true
end

local function RenderLoot(npcID, rare, top)
    local state = ns.PeekState(npcID)
    local loot, personal = LootList(npcID, rare)
    if personal then
        panel.LootHeader:SetText(L["Your loot (drop rate from your kills)"])
    elseif rare.forever then
        -- Chances measured by players in WoW Forever (items they never saw keep the estimate).
        panel.LootHeader:SetText(L["Loot (WoW Forever data from %d kills)"]:format(rare.forever))
    else
        panel.LootHeader:SetText(L["Loot (estimated drop chance)"])
    end
    panel.LootHeader:SetPoint("TOPLEFT", RIGHT_X, top)
    panel.LootHeader:SetShown(#loot > 0)
    local count = math.min(#loot, LOOT_MAX)
    for i = 1, count do
        local item = loot[i]
        local button = GetLootButton(i)
        local column, row = (i - 1) % LOOT_COLUMNS, math.floor((i - 1) / LOOT_COLUMNS)
        button:SetPoint("TOPLEFT", RIGHT_X + column * CELL_W, top - HEADER_GAP - row * CELL_H)
        button.itemID, button.chance, button.quest, button.personal = item[1], item[2], item[3], personal
        button.observed = item[4]  -- chance measured in WoW Forever rather than estimated
        button.looted = state and state.loot[item[1]] or 0
        button.Icon:SetTexture(C_Item.GetItemIconByID(item[1]))
        button.Border:SetVertexColor(QualityColor(C_Item.GetItemQualityByID(item[1])))
        button.Chance:SetText(ns.FormatChance(item[2]))
        if item[3] then
            button.Chance:SetTextColor(1, 0.82, 0)  -- quest items in yellow
        else
            button.Chance:SetTextColor(1, 1, 1)
        end
        button.Count:SetText(button.looted > 0 and ("x" .. button.looted) or "")
        button:Show()
    end
    for i = count + 1, #lootButtons do lootButtons[i]:Hide() end
    if count == 0 then return top end
    return top - HEADER_GAP - math.ceil(count / LOOT_COLUMNS) * CELL_H - 8
end

local function RenderWorldDrops(rare, top)
    panel.WorldHeader:SetPoint("TOPLEFT", RIGHT_X, top)
    local drops = rare.world or {}
    panel.WorldHeader:SetShown(#drops > 0)
    for i, drop in ipairs(drops) do
        local button = GetWorldButton(i)
        button.drop = drop
        local r, g, b = QualityColor(drop.q)
        local quality = _G["ITEM_QUALITY" .. drop.q .. "_DESC"] or "?"
        button.label:SetText(L["%s: %s per kill (%d items)"]:format(quality, ns.FormatChance(drop.c), drop.n))
        button.label:SetTextColor(r, g, b)
        button:SetPoint("TOPLEFT", RIGHT_X, top - HEADER_GAP - (i - 1) * 16)
        button:Show()
    end
    for i = #drops + 1, #worldButtons do worldButtons[i]:Hide() end
end

-- Tabs row; only shown when there is gear to list. Returns where the tab content starts.
local function RenderTabs(gearCount, top)
    local show = gearCount > 0
    panel.TabLoot:SetShown(show)
    panel.TabGear:SetShown(show)
    if not show then return top end
    panel.TabLoot:SetPoint("TOPLEFT", RIGHT_X, top)
    panel.TabGear:SetPoint("LEFT", panel.TabLoot, "RIGHT", 6, 0)
    panel.TabGear:SetText(L["Gear (%d)"]:format(gearCount))
    -- The selected tab is shown pressed (disabled).
    panel.TabLoot:SetEnabled(activeTab ~= "loot")
    panel.TabGear:SetEnabled(activeTab ~= "gear")
    return top - TAB_H - 10
end

local function HideLoot()
    panel.LootHeader:Hide()
    for _, button in ipairs(lootButtons) do button:Hide() end
end

local function RenderGear(gear, top, visible)
    for _, filter in ipairs(panel.GearFilters) do filter:SetShown(visible) end
    panel.GearScroll:SetShown(visible)
    panel.GearEmpty:Hide()
    if not visible then return end

    for i, filter in ipairs(panel.GearFilters) do
        filter:SetPoint("TOPLEFT", RIGHT_X + (i - 1) * 96, top)
        filter:SetEnabled(gearFilter ~= filter.key)
    end
    local gridTop = top - 28
    panel.GearScroll:ClearAllPoints()
    panel.GearScroll:SetPoint("TOPLEFT", RIGHT_X, gridTop)
    panel.GearScroll:SetPoint("BOTTOMRIGHT", panel, "TOPLEFT", RIGHT_X + GEAR_COLUMNS * GEAR_CELL,
        CONTENT_BOTTOM)

    local shown = 0
    for _, entry in ipairs(gear) do
        local classID = select(6, C_Item.GetItemInfoInstant(entry.itemID))
        if gearFilter == "all" or classID == gearFilter then
            shown = shown + 1
            local button = GetGearButton(shown)
            local column, row = (shown - 1) % GEAR_COLUMNS, math.floor((shown - 1) / GEAR_COLUMNS)
            button:SetPoint("TOPLEFT", column * GEAR_CELL, -row * GEAR_CELL)
            button.itemID, button.chance = entry.itemID, entry.chance
            button.Icon:SetTexture(C_Item.GetItemIconByID(entry.itemID))
            button.Border:SetVertexColor(QualityColor(entry.quality))
            button:Show()
        end
    end
    for i = shown + 1, #gearButtons do gearButtons[i]:Hide() end
    panel.GearContent:SetHeight(math.max(1, math.ceil(shown / GEAR_COLUMNS) * GEAR_CELL))
    panel.GearScroll:SetVerticalScroll(0)
    if shown == 0 then
        panel.GearEmpty:SetPoint("TOPLEFT", RIGHT_X, gridTop - 6)
        panel.GearEmpty:Show()
    end
end

local function Render(npcID)
    local rare = ns.Rares[npcID]
    panel.Title:SetText(ns.GetName(npcID))
    panel.Model:ClearModel()
    if rare.display then
        panel.Model:SetDisplayInfo(rare.display)
    else
        panel.Model:SetCreature(npcID)  -- rares recorded in game have no display ID
    end
    panel.Model.facing, panel.Model.zoom = 0, 1
    panel.Model:SetFacing(0)
    panel.Model:SetCamDistanceScale(1)
    RenderInfo(npcID, rare)
    local top = RenderSpells(rare, CONTENT_TOP)
    local gear = GearList(rare)
    if #gear == 0 then activeTab = "loot" end
    top = RenderTabs(#gear, top)
    local showLoot = activeTab == "loot"
    if showLoot then
        RenderWorldDrops(rare, RenderLoot(npcID, rare, top))
    else
        HideLoot()
        for _, button in ipairs(worldButtons) do button:Hide() end
        panel.WorldHeader:Hide()
    end
    RenderGear(gear, top, not showLoot)
end

-- Public API ---------------------------------------------------------------------
function DetailPanel.Show(npcID)
    if not ns.Rares[npcID] then return end
    if not panel then CreatePanel() end
    currentID = npcID
    for _, loot in ipairs(ns.Rares[npcID].loot) do C_Item.RequestLoadItemDataByID(loot[1]) end
    Render(npcID)
    panel:Show()
end

function DetailPanel.Refresh(npcID)
    if panel and panel:IsShown() and (npcID == nil or npcID == currentID) then
        Render(currentID)
    end
end

local refreshPending = false
ns.On("GET_ITEM_INFO_RECEIVED", function()
    if refreshPending or not (panel and panel:IsShown()) then return end
    refreshPending = true
    C_Timer.After(0.3, function()
        refreshPending = false
        DetailPanel.Refresh()
    end)
end)
