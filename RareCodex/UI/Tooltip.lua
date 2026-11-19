-- Tooltip: compact summary shown when hovering a rare's map pin.
local _, ns = ...

local Tooltip = {}
ns.Tooltip = Tooltip

local MAX_TOOLTIP_ITEMS = 4
local RARE_COLOR = { 0.4, 0.8, 1.0 }
local MUTED = { 0.7, 0.7, 0.7 }

local function SpellName(spellID)
    local info = C_Spell.GetSpellInfo(spellID)
    return info and info.name
end

function Tooltip.ShowRare(owner, npcID)
    local rare = ns.Rares[npcID]
    local state = ns.PeekState(npcID)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:AddLine(ns.GetName(npcID), RARE_COLOR[1], RARE_COLOR[2], RARE_COLOR[3])

    local level = rare.level[1] == rare.level[2] and rare.level[1]
        or (rare.level[1] .. "-" .. rare.level[2])
    GameTooltip:AddLine(("Level %s %s"):format(level, rare.elite and "Rare Elite" or "Rare"), 1, 1, 1)
    GameTooltip:AddDoubleLine("Respawn", ns.FormatRespawn(rare), MUTED[1], MUTED[2], MUTED[3], 1, 1, 1)

    local spells = {}
    for _, spellID in ipairs(rare.spells) do
        spells[#spells + 1] = SpellName(spellID)
    end
    if #spells > 0 then
        GameTooltip:AddLine("Abilities: " .. table.concat(spells, ", "), 1, 0.6, 0.3, true)
    end
    if rare.flee then
        GameTooltip:AddLine(("Flees at %d%% health"):format(rare.flee), 1, 0.4, 0.4)
    end

    if state and state.lastSeen then
        GameTooltip:AddDoubleLine("Last seen", ns.FormatAgo(state.lastSeen), MUTED[1], MUTED[2], MUTED[3], 1, 1, 1)
    else
        GameTooltip:AddLine("Never seen", 1, 0.3, 0.3)
    end
    GameTooltip:AddDoubleLine("Kills", state and state.kills or 0, MUTED[1], MUTED[2], MUTED[3], 1, 1, 1)

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
    GameTooltip:AddLine("Click: details   Shift-click: waypoint", 0.5, 1, 0.5)
    GameTooltip:Show()
end
