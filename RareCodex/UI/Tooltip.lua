-- Tooltip: compact summary shown when hovering a rare's map pin.
local _, ns = ...
local L = ns.L

local Tooltip = {}
ns.Tooltip = Tooltip

local MAX_TOOLTIP_ITEMS = 4
local RARE_COLOR = { 0.4, 0.8, 1.0 }
local MUTED = { 0.7, 0.7, 0.7 }

local function SpellName(spellID)
    local info = C_Spell.GetSpellInfo(spellID)
    return info and info.name
end

local function AddMutedPair(left, right)
    GameTooltip:AddDoubleLine(left, right, MUTED[1], MUTED[2], MUTED[3], 1, 1, 1)
end

function Tooltip.ShowRare(owner, npcID)
    local rare = ns.Rares[npcID]
    local state = ns.PeekState(npcID)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:AddLine(ns.GetName(npcID), RARE_COLOR[1], RARE_COLOR[2], RARE_COLOR[3])
    GameTooltip:AddLine(L["Level %s %s"]:format(ns.FormatLevel(rare), ns.FormatRank(rare)), 1, 1, 1)
    AddMutedPair(L["Respawn"], ns.FormatRespawn(rare))
    if #rare.spawns > 1 then
        GameTooltip:AddLine(L["Spawns at one of %d points (dots on the map)"]:format(#rare.spawns),
            MUTED[1], MUTED[2], MUTED[3])
    end
    if rare.unknown then
        GameTooltip:AddLine(L["Recorded in game: no ability or loot data yet."], 1, 0.82, 0, true)
    end

    local spells = {}
    for _, spellID in ipairs(rare.spells) do
        spells[#spells + 1] = SpellName(spellID)
    end
    if #spells > 0 then
        GameTooltip:AddLine(L["Abilities: %s"]:format(table.concat(spells, ", ")), 1, 0.6, 0.3, true)
    end
    if rare.flee then
        GameTooltip:AddLine(L["Flees at %d%% health"]:format(rare.flee), 1, 0.4, 0.4)
    end

    if state and state.lastSeen then
        AddMutedPair(L["Last seen"], ns.FormatAgo(state.lastSeen))
    else
        GameTooltip:AddLine(L["Never seen"], 1, 0.3, 0.3)
    end
    AddMutedPair(L["Kills"], state and state.kills or 0)

    local shown = 0
    for _, loot in ipairs(rare.loot) do
        if shown >= MAX_TOOLTIP_ITEMS then break end
        if not loot[3] then  -- skip quest items in the summary
            local name, link = C_Item.GetItemInfo(loot[1])
            GameTooltip:AddDoubleLine(link or name or ("item:" .. loot[1]), ns.FormatChance(loot[2]))
            shown = shown + 1
        end
    end

    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(L["Click: details   Shift-click: waypoint"], 0.5, 1, 0.5)
    GameTooltip:Show()
end
