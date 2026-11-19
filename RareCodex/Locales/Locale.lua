-- Locale: ns.L["English text"] returns the translation for the client language, or the
-- English text itself when there is none. Translations live in Locales/<locale>.lua.
local _, ns = ...

ns.L = setmetatable({}, {
    __index = function(_, key) return key end,
})
