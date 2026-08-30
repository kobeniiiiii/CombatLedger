--[[
    CombatLedger v0.3.0

    A combat meter built on Nampower's structured combat events
    (AUTO_ATTACK_SELF/OTHER, SPELL_DAMAGE_EVENT_SELF/OTHER, SPELL_HEAL_BY_*,
    SPELL_DISPEL_*, AURA_CAST_ON_*/DEBUFF_ADDED_*) instead of parsing
    CHAT_MSG_COMBAT_* text like most vanilla meters - real numeric fields
    (damage amount, spell ID, hit type) instead of regexing a localized
    string.

    Tracks Damage/Healing/Damage Taken/Dispels/Debuffs Given/Deaths, each
    with a click-through per-ability/per-target breakdown, across any
    number of independent meter windows (see UI_MainWindow.lua), plus
    Current Fight/Overall/saved History segments and a death recap. Set
    CL.debug = true (or /cl debug) to log every raw event to
    CL.LOG_FILENAME via LogLine/FlushLog below - chat gets unreadable fast
    under real combat event volume, so verification goes to a plain file
    instead.
]]

-- Shared namespace table - every other file attaches its own pieces to
-- this (CL.GuidCache, CL.Aggregator, ...) since plain `local`s don't
-- cross file boundaries the way they do in LootLedger's single-file
-- layout. Each file starts with `local CL = CombatLedger`.
CombatLedger = CombatLedger or {}
local CL = CombatLedger

-- Keybind support - Bindings.xml maps the key to CombatLedger.UI.Toggle()
-- via this action name; these globals supply the label text shown in
-- the Blizzard Key Bindings panel (BINDING_HEADER_/BINDING_NAME_ is the
-- vanilla 1.12 convention, not a CombatLedger-specific mechanism).
BINDING_HEADER_COMBATLEDGER_TITLE = "CombatLedger"
BINDING_NAME_COMBATLEDGER_TOGGLE = "Toggle CombatLedger windows"

CombatLedgerDB = CombatLedgerDB or { encounters = {} }
CombatLedgerDB.encounters = CombatLedgerDB.encounters or {}
CombatLedgerDB.settings = CombatLedgerDB.settings or {}
CL.db = CombatLedgerDB

-- Encounter-end timing - deliberately NOT a user setting (no Options
-- control, no /cl set). See Events.lua's OnUpdate idle check for the
-- full reasoning - PLAYER_REGEN_ENABLED no longer ends an encounter
-- directly; ending is entirely "no relevant event for this long," using
-- one of these two thresholds depending on the player's own combat flag.
--
-- IDLE_SECONDS: the training-dummy fallback - some targets on at least
-- this server never toggle the regen flag at all, so without this an
-- encounter against one would never end on its own. Long, since the
-- player might genuinely still be mid-fight themselves.
CL.IDLE_SECONDS = 12
-- POST_COMBAT_IDLE_SECONDS: once the player's own flag HAS cleared, this
-- is the real "is anyone in the tracked roster still doing anything"
-- window - short, since nobody's personally fighting from this client's
-- point of view anymore, just long enough to absorb a last DoT tick/
-- heal/overkill without chopping it off mid-fall.
CL.POST_COMBAT_IDLE_SECONDS = 3

-- Tunable settings, saved-variable-backed so they survive /reload and
-- exposed in the Options window - see UI_Options.lua.
CL.defaultSettings = {
    matchPfui = true, -- while true (and pfUI is loaded), bar texture + font mirror pfUI's own instead of barTexture/fontKey/fontSize below
    barTexture = "flat", -- pfUI's own flat bar look, bundled in img/bar.tga (see CL.GetBarTexture) - the default even without pfUI installed
    hideBorder = false, -- ShaguDPS-style borderless window, independent of matchPfui
    fontKey = "friz",
    fontSize = 10,
    barHeight = nil, -- nil = each window's own built-in default
    smoothBars = true,
    barSpeed = 8, -- 1 (slow drift) - 10 (near-instant), only used while smoothBars is on
    numberFormat = "abbreviated", -- "abbreviated" (1.2k) / "full" (1,234) / "raw" (1234)
    lockWindow = false,
    showMinimapButton = true,
    announceChannel = "auto", -- "auto" (raid > party > say) / "say" / "party" / "raid" / "guild"
    announceCount = 5,
    windowOpacityPct = 81, -- background alpha, as a percent - ignored while matchPfui is on (81 matches the flat skin's pfUI-derived look)
    -- autoShowInCombat/autoHideOutOfCombat used to live here - now
    -- per-window via CL.GetWindowOption/SetWindowOption (see below),
    -- since different meter windows want different behavior.
    pfuiDock = false, -- dock the main window into pfUI's right chat panel (see UI_PfuiDock.lua) - opt-in, since it moves/resizes the window
    showClassIcon = false, -- class icon before the name on each bar - opt-in, redundant with the existing class-colored bar fill for some tastes
    classColorMenus = false, -- header/dropdown buttons take the player's class color instead of the flat near-black default - see CL.ApplyButtonSkin
    highlightSelf = false, -- border around whichever bar is the player's own, in highlightSelfColor below - opt-in, some people find a border on every meter distracting
    highlightSelfColor = { 1, 0.82, 0 }, -- user-customizable via Options' color picker - gold by default, matching this addon's existing "pay attention to this" accent color
    barBorderEnabled = false, -- border around EVERY bar, in barBorderColor below - independent of highlightSelf, which always wins on your own row regardless of this
    barBorderColor = { 1, 1, 1 }, -- user-customizable via Options' color picker
    clearOnJoinPartyMode = "off", -- "off" / "always" / "ask" - auto-resets (or offers to reset) the Overall segment the moment you go from solo to grouped (party or raid) - see Events.lua's group-change handler

    announcePulls = true, -- "Pull: X (spell)" chat print at the start of a boss encounter (not regular elite trash) - see Aggregator.lua's IsBossTaggedEnemy
}

-- Defensive rather than relying purely on the load-time "or {}" above:
-- this client restores saved variables from disk AFTER Core.lua's own
-- init line runs, and that restore REPLACES CombatLedgerDB wholesale -
-- an existing save from before .settings existed wipes it back to nil.
local function EnsureSettingsTable()
    if not CombatLedgerDB.settings then
        CombatLedgerDB.settings = {}
    end
end

function CL.GetSetting(key)
    EnsureSettingsTable()
    local v = CombatLedgerDB.settings[key]
    if v == nil then return CL.defaultSettings[key] end
    return v
end

function CL.SetSetting(key, value)
    EnsureSettingsTable()
    CombatLedgerDB.settings[key] = value
end

-- Per-window size/position, saved-variable-backed same as settings
-- above (same defensive EnsureX pattern, same reason - this client
-- replaces CombatLedgerDB wholesale on restore, after Core.lua's own
-- init line runs). `key` is a short per-window id ("main", "breakdown",
-- "deathRecap", "history").
local function EnsureLayoutTable()
    if not CombatLedgerDB.layout then
        CombatLedgerDB.layout = {}
    end
end

function CL.GetLayout(key)
    EnsureLayoutTable()
    return CombatLedgerDB.layout[key]
end

function CL.SaveLayout(key, frame)
    EnsureLayoutTable()
    local point, _, relPoint, x, y = frame:GetPoint(1)
    CombatLedgerDB.layout[key] = {
        width = frame:GetWidth(),
        height = frame:GetHeight(),
        point = point or "CENTER",
        relPoint = relPoint or "CENTER",
        x = x or 0,
        y = y or 0,
    }
end

-- Applies a saved layout if one exists (returns true), otherwise leaves
-- the frame's already-set default width/height/point alone (false).
-- minW/minH/maxW/maxH are optional - clamps a saved size into a
-- window's current bounds, since a size saved under an earlier layout
-- (before a resize/redesign changed that window's min size) could
-- otherwise restore smaller than the new layout can actually fit,
-- leaving elements overlapping instead of properly stacked.
function CL.ApplyLayout(key, frame, minW, minH, maxW, maxH)
    local saved = CL.GetLayout(key)
    if not saved then return false end
    if saved.width then
        local w = saved.width
        if minW and w < minW then w = minW end
        if maxW and w > maxW then w = maxW end
        frame:SetWidth(w)
    end
    if saved.height then
        local h = saved.height
        if minH and h < minH then h = minH end
        if maxH and h > maxH then h = maxH end
        frame:SetHeight(h)
    end
    frame:ClearAllPoints()
    frame:SetPoint(saved.point or "CENTER", UIParent, saved.relPoint or "CENTER", saved.x or 0, saved.y or 0)
    return true
end

-- Multi-window support: which extra meter windows (beyond the always-
-- present "main") should exist, and each window's own mode/segment
-- choice - same defensive EnsureX/wholesale-replace reasoning as
-- settings/layout above. Presence of a non-"main" key is what makes
-- UI_MainWindow.lua's UI.RestoreAllWindows() recreate that window on
-- login; UI.CloseExtraWindow removes its key so it doesn't come back.
local function EnsureWindowsTable()
    if not CombatLedgerDB.windows then
        CombatLedgerDB.windows = {}
    end
end

function CL.GetWindowState(id)
    EnsureWindowsTable()
    return CombatLedgerDB.windows[id]
end

function CL.SaveWindowState(id, mode, segment, threatFilter)
    EnsureWindowsTable()
    CombatLedgerDB.windows[id] = { mode = mode, segment = segment, threatFilter = threatFilter }
end

function CL.ForgetWindowState(id)
    EnsureWindowsTable()
    CombatLedgerDB.windows[id] = nil
    if CombatLedgerDB.windowOptions then
        CombatLedgerDB.windowOptions[id] = nil
    end
end

-- Per-window auto-show/auto-hide/only-while-grouped toggles - used to
-- be addon-wide settings, but a Threat meter you only want up while
-- grouped and fighting has nothing to do with whether your always-on
-- Damage meter should behave the same way, so each window now carries
-- its own copy. Kept in a separate table from CL.SaveWindowState's
-- mode/segment/threatFilter, which gets wholesale-replaced on every
-- mode/segment change - these would otherwise risk getting clobbered
-- back to stale values by the next unrelated SaveWindowState call.
local function EnsureWindowOptionsTable()
    if not CombatLedgerDB.windowOptions then
        CombatLedgerDB.windowOptions = {}
    end
end

function CL.GetWindowOption(id, key, default)
    EnsureWindowOptionsTable()
    local opts = CombatLedgerDB.windowOptions[id]
    if not opts or opts[key] == nil then return default end
    return opts[key]
end

function CL.SetWindowOption(id, key, value)
    EnsureWindowOptionsTable()
    if not CombatLedgerDB.windowOptions[id] then
        CombatLedgerDB.windowOptions[id] = {}
    end
    CombatLedgerDB.windowOptions[id][key] = value
end

-- Every remembered window id other than "main" (which is handled
-- separately since it always exists and is never closable).
function CL.GetExtraWindowIds()
    EnsureWindowsTable()
    local ids = {}
    local id, _
    for id, _ in pairs(CombatLedgerDB.windows) do
        if id ~= "main" then
            table.insert(ids, id)
        end
    end
    return ids
end

-- Shared by every StatusBar-based window (UI_MainWindow, UI_Breakdown,
-- UI_DeathRecap) so the meter's bars actually match pfUI's own bars
-- instead of looking like a different addon. pfUI.media["img:bar"] is
-- the exact texture pfUI itself uses for every one of its bars (and
-- what it applies when it skins other addons' status bars too - see
-- pfUI/modules/thirdparty-vanilla.lua).
-- Asks the client's own addon manager directly (IsAddOnLoaded) instead
-- of inferring pfUI's presence from the shape of the `pfUI` global -
-- confirmed on a client with pfUI genuinely not loaded (IsAddOnLoaded
-- returns nil, verified both from the AddOns list and visually - a
-- completely unstyled vanilla UI, no pfUI skin anywhere) that `pfUI`,
-- `pfUI.api`, and even `pfUI.api.CreateBackdrop` as a real callable
-- function were ALL still present. Something else on this client
-- fully populates a pfUI-shaped table without pfUI ever loading, so no
-- amount of inspecting that table's shape can be made reliable -
-- IsAddOnLoaded is authoritative and sidesteps the whole problem.
function CL.HasPfui()
    local ok, loaded = pcall(IsAddOnLoaded, "pfUI")
    return ok and loaded and true or false
end

-- "Match pfUI" (default on) mirrors pfUI's own bar texture/font exactly,
-- same as this addon's bars did before Options existed. Turning it off
-- unlocks the manual barTexture/fontKey/fontSize choices below - the
-- Options window greys those controls out while this is on, since
-- they'd have no visible effect.
function CL.IsMatchPfui()
    return CL.HasPfui() and (CL.GetSetting("matchPfui") ~= false)
end

-- "Flat" is pfUI's own default bar look (img/bar.tga), bundled directly
-- in this addon's own img/ folder (MIT-licensed from pfUI - see
-- README) so it's available and looks identical whether or not pfUI is
-- actually installed - this used to be exclusive to pfUI users via
-- "Match pfUI", which only helps if you already run pfUI. It's the
-- default (see CL.defaultSettings) - Blizzard/Smooth Gradient are still
-- here for anyone who wants the classic look back.
--
-- Previously also listed four "pfui_*" entries (elvui/gradient/striped/
-- tukui) pointing at pfUI.media["img:bar_elvui"] etc. - removed, because
-- those keys don't exist. Checked pfUI's actual source: every single
-- pfUI file that skins a status bar reads pfUI.media["img:bar"] only -
-- that's pfUI's ONE currently-selected bar texture (whatever the user
-- picked in pfUI's own settings), not five separately-registered skin
-- variants. Those four entries always resolved to nil, so cycling onto
-- any of them called SetStatusBarTexture(nil), which silently no-ops
-- and leaves whatever texture was already showing - this is what "bar
-- texture doesn't change" turned out to be.
--
-- Fixed for real by bundling the actual .tga files (img/bar_elvui.tga
-- etc, MIT-licensed from pfUI - see README) directly, same as
-- img/bar.tga - these are genuinely pfUI's own alternate bar skins, just
-- shipped as this addon's own assets instead of a broken lookup into
-- pfUI's media table.
CL.BAR_TEXTURES = {
    { key = "flat", label = "Flat (default)" },
    { key = "blizzard", label = "Blizzard Default" },
    { key = "raid", label = "Smooth Gradient", file = "bar_smooth" },
    { key = "elvui", label = "ElvUI Style", file = "bar_elvui" },
    { key = "gradient", label = "pfUI Gradient", file = "bar_gradient" },
    { key = "striped", label = "Striped", file = "bar_striped" },
    { key = "tukui", label = "TukUI Style", file = "bar_tukui" },
}

function CL.GetAvailableBarTextures()
    return CL.BAR_TEXTURES
end

function CL.GetBarTexture()
    if CL.IsMatchPfui() and pfUI.media and pfUI.media["img:bar"] then
        return pfUI.media["img:bar"]
    end
    local key = CL.GetSetting("barTexture") or "flat"
    if key == "flat" then
        return "Interface\\AddOns\\CombatLedger\\img\\bar"
    end
    if key ~= "blizzard" then
        local i
        for i = 1, table.getn(CL.BAR_TEXTURES) do
            local t = CL.BAR_TEXTURES[i]
            if t.key == key and t.file then
                return "Interface\\AddOns\\CombatLedger\\img\\" .. t.file
            end
        end
    end
    return "Interface\\TargetingFrame\\UI-StatusBar"
end

-- The client's own built-in font files - no LibSharedMedia dependency,
-- so this works standalone. Covers the handful of fonts every 1.12
-- client ships with.
CL.FONTS = {
    { key = "friz", label = "Friz Quadrata (default)", path = "Fonts\\FRIZQT__.TTF" },
    { key = "arial", label = "Arial Narrow", path = "Fonts\\ARIALN.TTF" },
    { key = "skurri", label = "Skurri", path = "Fonts\\SKURRI.TTF" },
    { key = "morpheus", label = "Morpheus", path = "Fonts\\MORPHEUS.ttf" },
    -- Not a stock client font - bundled from pfUI (fonts/Expressway.ttf,
    -- MIT-licensed, see README), same reasoning as img/bar.tga.
    { key = "expressway", label = "Expressway", path = "Interface\\AddOns\\CombatLedger\\fonts\\Expressway.ttf" },
}

function CL.GetFontPath()
    if CL.IsMatchPfui() and pfUI.font_default then
        return pfUI.font_default
    end
    local key = CL.GetSetting("fontKey") or "friz"
    local i
    for i = 1, table.getn(CL.FONTS) do
        if CL.FONTS[i].key == key then return CL.FONTS[i].path end
    end
    return "Fonts\\FRIZQT__.TTF"
end

function CL.GetFontSize()
    if CL.IsMatchPfui() and pfUI_config and pfUI_config.global and pfUI_config.global.font_size then
        return pfUI_config.global.font_size
    end
    return CL.GetSetting("fontSize") or 10
end

-- Applies the current font CHOICE to any FontString - call at creation
-- and again from an appearance-changed listener (see below) so already-
-- created FontStrings pick up a change without a /reload.
--
-- `size` is optional - pass CL.GetFontSize() explicitly for bar text
-- (the one thing the "Font size" Options slider is meant to control).
-- Everywhere else, omit it: the font FAMILY should apply everywhere
-- (title bars, labels, Options controls, ...), but a title shouldn't
-- shrink down to bar-text size just because the family changed, so
-- this preserves whatever size the FontString already had (its
-- template's size, e.g. GameFontNormalLarge vs GameFontHighlightSmall).
function CL.ApplyFont(fontString, size)
    if not fontString then return end
    if not size then
        local _, curSize = fontString:GetFont()
        size = curSize or CL.GetFontSize()
    end
    fontString:SetFont(CL.GetFontPath(), size, "OUTLINE")
end

-- Walks a frame and every descendant, applying the font CHOICE (native
-- size preserved, same as a bare CL.ApplyFont call) to every FontString
-- found - covers titles/headers/checkbox labels/stepper values/etc
-- without having to hand-instrument each one at creation time. Safe to
-- call on a whole window; a caller that wants specific elements (bar
-- text) at CL.GetFontSize() should call CL.ApplyFont on those AFTER
-- this, since this only ever preserves native size.
function CL.ApplyFontToTree(frame)
    if not frame then return end
    local regions = { frame:GetRegions() }
    local i
    for i = 1, table.getn(regions) do
        local r = regions[i]
        if r.SetFont and r.GetFont then
            CL.ApplyFont(r)
        end
    end
    local children = { frame:GetChildren() }
    for i = 1, table.getn(children) do
        CL.ApplyFontToTree(children[i])
    end
end

-- Bar height is per-window by default (each meter window has its own
-- sensible built-in constant) but Options can override all of them at
-- once - `default` is that window's own constant, used when no override
-- is set.
function CL.GetBarHeight(default)
    return CL.GetSetting("barHeight") or default
end

-- Vanilla's full strata order, lowest to highest. Used by
-- CL.NextLowerStrata below - a plain BACKGROUND constant for "one level
-- behind whatever window this is attached to" only worked back when
-- every CombatLedger window sat somewhere in the MEDIUM/DIALOG middle
-- of this list, where BACKGROUND really was several levels below all
-- of them. Once the main window moved to TOOLTIP (the top), a
-- BACKGROUND-strata shadow left a huge gap - literally every other
-- strata in between - for any other addon's frame to render on top of
-- it, instead of the shadow staying visually attached to its own
-- window like it does for everything else.
CL.STRATA_ORDER = { "BACKGROUND", "LOW", "MEDIUM", "HIGH", "DIALOG", "FULLSCREEN", "FULLSCREEN_DIALOG", "TOOLTIP" }

function CL.NextLowerStrata(strata)
    local i
    for i = 1, table.getn(CL.STRATA_ORDER) do
        if CL.STRATA_ORDER[i] == strata then
            return CL.STRATA_ORDER[math.max(1, i - 1)]
        end
    end
    return "BACKGROUND" -- unrecognized input - safest fallback
end

-- One tier above whatever strata is passed in - used by CL.ShowDropdown
-- so a submenu always renders just above whatever button opened it,
-- regardless of that button's own window's strata, instead of every
-- dropdown claiming the single topmost TOOLTIP tier unconditionally
-- (which used to outrank real Blizzard tooltips/frames for no reason
-- beyond "definitely on top").
function CL.NextHigherStrata(strata)
    local i
    for i = 1, table.getn(CL.STRATA_ORDER) do
        if CL.STRATA_ORDER[i] == strata then
            return CL.STRATA_ORDER[math.min(table.getn(CL.STRATA_ORDER), i + 1)]
        end
    end
    return "TOOLTIP" -- unrecognized input - safest fallback (definitely on top)
end

-- Background alpha for every window's backdrop - only applied while
-- "Match pfUI" is off (pfUI's own skin governs backdrop appearance
-- otherwise, so this would have no visible effect and Options greys the
-- control out).
function CL.GetWindowOpacity()
    return (CL.GetSetting("windowOpacityPct") or 81) / 100
end

-- `fallback` is a window's own original backdrop alpha, used while
-- "Match pfUI" is on (pfUI's skin governs the look then, so the manual
-- opacity setting would have no visible effect anyway).
function CL.GetBackdropAlpha(fallback)
    if CL.IsMatchPfui() then return fallback end
    return CL.GetWindowOpacity()
end

-- Flat WHITE8X8 panel, matching pfUI's own default (non-"thin",
-- non-blizzard-forced) window backdrop exactly - same texture for both
-- background and edge (tinted separately via SetBackdropColor/
-- BackdropBorderColor), 1px edge, background inset -1px past the edge
-- so there's no gap between them. This used to be Blizzard's rounded
-- Tooltip border, a completely different look from pfUI's minimal
-- style - see CL.ApplyWindowSkin below for why that mattered.
CL.WINDOW_BACKDROP = {
    bgFile = "Interface\\BUTTONS\\WHITE8X8", tile = false, tileSize = 0,
    edgeFile = "Interface\\BUTTONS\\WHITE8X8", edgeSize = 1,
    insets = { left = -1, right = -1, top = -1, bottom = -1 },
}

-- Soft drop shadow, matching pfUI's own backdrop_shadow - img/glow2.tga
-- is pfUI's actual shadow texture, bundled here the same way img/bar.tga
-- is (MIT-licensed, see README). 5px larger than the frame on every
-- side, same as pfUI's own anchor offsets.
CL.WINDOW_SHADOW = {
    edgeFile = "Interface\\AddOns\\CombatLedger\\img\\glow2", edgeSize = 8,
    insets = { left = 0, right = 0, top = 0, bottom = 0 },
}

-- Near-black border/background - not a guess, this is one real pfUI
-- user's own actual tweaked appearance settings (border.color/
-- background from their pfUI SavedVariables), used here as the new
-- manual-skin default so the look doesn't require pfUI at all. Applies
-- everywhere the manual (non-"Match pfUI") skin renders a border -
-- window and buttons alike - rather than this addon's own theme/class
-- color, matching "Match pfUI"'s own existing rule that only text stays
-- class-colored, not chrome.
CL.FLAT_BORDER_R, CL.FLAT_BORDER_G, CL.FLAT_BORDER_B = 0.059, 0.059, 0.059

-- Applies pfUI's own skin to a window's backdrop when "Match pfUI" is on
-- (and pfUI is loaded), otherwise (re)applies this addon's own plain
-- backdrop at the chosen opacity - called both at window creation and
-- from the appearance-changed listener, so toggling the setting at
-- runtime actually changes the window's look instead of only whichever
-- one was true at creation time sticking forever. `borderR/G/B` is the
-- border color to use either way.
--
-- pfUI.api.CreateBackdrop does NOT skin `f` directly - it blanks f's own
-- backdrop (SetBackdrop(nil)) and parks its skin on a separate child
-- frame (f.backdrop, plus f.backdrop_shadow from CreateBackdropShadow),
-- and only creates that child once (later calls just reposition/re-skin
-- the existing one). Switching to manual mode has to explicitly Hide()
-- those children (they don't go away on their own) and restore f's own
-- backdrop; switching back to pfUI mode has to explicitly null f's own
-- backdrop again (CreateBackdrop only does that the very first time) -
-- otherwise toggling the setting either leaves an orphaned pfUI border/
-- shadow behind, or leaves our manual backdrop fighting with pfUI's.
function CL.ApplyWindowSkin(f, borderR, borderG, borderB, opacityFallback)
    if CL.IsMatchPfui() and pfUI.api then
        local ok = pcall(function()
            pfUI.api.CreateBackdrop(f)
            pfUI.api.CreateBackdropShadow(f)
        end)
        if ok and f.backdrop then
            f:SetBackdrop(nil)
            f.backdrop:Show()
            -- Deliberately NOT re-tinting the border to theme color here
            -- - "Match pfUI" means look like pfUI, full stop; only text
            -- (title, bar names, ...) stays class-colored.
            if f.backdrop_shadow then f.backdrop_shadow:Show() end
            return
        end
    end
    if f.backdrop then f.backdrop:Hide() end
    if f.backdrop_shadow then f.backdrop_shadow:Hide() end
    f:SetBackdrop(CL.WINDOW_BACKDROP)
    f:SetBackdropColor(0, 0, 0, CL.GetBackdropAlpha(opacityFallback))
    -- ShaguDPS-style borderless option - just the edge line goes
    -- transparent, background/bars are unaffected. Independent of
    -- matchPfui (only applies in this manual-skin branch; pfUI's own
    -- skin bakes its border into one texture, not selectively hideable).
    if CL.GetSetting("hideBorder") then
        f:SetBackdropBorderColor(0, 0, 0, 0)
    else
        f:SetBackdropBorderColor(CL.FLAT_BORDER_R, CL.FLAT_BORDER_G, CL.FLAT_BORDER_B, 1)
    end

    -- Own shadow frame for the manual skin, same idea as pfUI's
    -- backdrop_shadow child - created once, just re-shown/re-hidden
    -- after that (same pattern as pfUI's f.backdrop above).
    if not CL.GetSetting("hideBorder") then
        if not f.flatShadow then
            f.flatShadow = CreateFrame("Frame", nil, f)
            -- One strata below f's own (not a flat BACKGROUND constant -
            -- see CL.NextLowerStrata's comment for why) so it reliably
            -- sits just behind its own window regardless of frame level,
            -- without leaving a gap other addons' frames can render into
            -- when f itself is high up the strata order (e.g. a
            -- dropdown submenu, dynamically strata'd via
            -- CL.NextHigherStrata in ShowDropdown).
            f.flatShadow:SetFrameStrata(CL.NextLowerStrata(f:GetFrameStrata()))
            f.flatShadow:SetFrameLevel(1)
            f.flatShadow:SetPoint("TOPLEFT", f, "TOPLEFT", -5, 5)
            f.flatShadow:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 5, -5)
            f.flatShadow:SetBackdrop(CL.WINDOW_SHADOW)
        end
        f.flatShadow:SetBackdropBorderColor(0, 0, 0, 0.35)
        f.flatShadow:Show()
    elseif f.flatShadow then
        f.flatShadow:Hide()
    end
end

-- Skins a small manually-built button (CreateHeaderButton-style: own
-- backdrop already set, hover/tooltip already wired via SetScript
-- before this runs) with pfUI's look while Match pfUI is on, otherwise
-- just asserts the theme border color. Unlike CreateBackdrop, pfUI's
-- SkinButton sets the backdrop directly on the button itself (no child
-- frame), so there's no orphaned-frame cleanup needed here.
--
-- "Match pfUI" means look like pfUI, full stop - the base backdrop/
-- border color at rest comes from pfUI's own skin (not re-tinted to
-- theme). Hover is a different story: SkinButton's disableHighlight
-- arg is passed true here so pfUI's own OnEnter/OnLeave hover hook
-- (pfUI.api.SetHighlight) never gets installed on these buttons at all
-- - it's a second, independent hover mechanism built on the same raw
-- OnEnter/OnLeave events we already found unreliable on this client
-- (see SetButtonTooltip's own OnUpdate-poll rewrite), and since it
-- fights over the exact same backdrop border, leaving it enabled meant
-- the click/hover-stuck bug kept happening via pfUI's own hook even
-- after our side was fixed. SetButtonTooltip's OnUpdate poll owns hover
-- unconditionally now instead, including while matching pfUI.
--
-- The manual-skin branch below uses the near-black FLAT_BORDER_* by
-- default (consistent flat look, not theme-colored chrome mixed with a
-- neutral window border) - unless "Show class colored menus" is on,
-- which brings back the passed-in borderR/G/B (the player's class
-- color, from CL.GetThemeColor) instead. Off by default; some people
-- want the buttons to pick up their class color, others find it
-- clashes with the flat neutral window.
-- The fill/backdrop color a CreateHeaderButton-style button should show
-- at rest right now - pfUI's own configured border-background while
-- matching pfUI (same color CreateBackdrop's legacy branch just used
-- inside SkinButton above), otherwise the flat default. Shared with
-- UI_MainWindow.lua's SetButtonTooltip, whose OnUpdate re-asserts this
-- EVERY frame rather than only on mouse-up/a press timeout - a hardcoded
-- near-black revert used to fight with pfUI's real (different) color
-- whenever Match pfUI was on, leaving a clicked button stuck showing
-- the wrong tone against its never-yet-clicked neighbors.
function CL.GetButtonNormalFill()
    if CL.IsMatchPfui() and pfUI.api and pfUI.api.GetStringColor and pfUI_config then
        local ok, r, g, b, a = pcall(pfUI.api.GetStringColor, pfUI_config.appearance.border.background)
        if ok and r then return r, g, b, a end
    end
    return 0.12, 0.12, 0.14, 0.9
end

function CL.ApplyButtonSkin(btn, borderR, borderG, borderB)
    local matchedPfui = false
    if CL.IsMatchPfui() and pfUI.api then
        local ok = pcall(pfUI.api.SkinButton, btn, nil, nil, nil, nil, true)
        matchedPfui = ok
    end
    -- classColorMenus is an explicit opt-in override - it wins even over
    -- pfUI's own skin border, otherwise it has zero visible effect for
    -- anyone running with "Match pfUI" on (the default), since SkinButton
    -- above would already have claimed the border first.
    if CL.GetSetting("classColorMenus") then
        btn:SetBackdropBorderColor(borderR, borderG, borderB, 1)
    elseif not matchedPfui then
        btn:SetBackdropBorderColor(CL.FLAT_BORDER_R, CL.FLAT_BORDER_G, CL.FLAT_BORDER_B, 1)
    end
end

-- Lightweight click-menu, shared by anything that needs a real dropdown
-- (the main meter's Mode/Segment buttons, Options' Bar texture/Font/
-- Number format pickers) - a plain frame + pooled row buttons rather
-- than Blizzard's UIDropDownMenu, which is finicky to reuse outside its
-- own templates on this client. Only one can be open at a time
-- regardless of which button opened it, so this lives here once instead
-- of every window that wants one building its own copy.
local dropdownFrame = nil
local dropdownCatcher = nil -- full-screen invisible button that closes the menu on an outside click

function CL.CloseDropdown()
    if dropdownFrame then dropdownFrame:Hide() end
    if dropdownCatcher then dropdownCatcher:Hide() end
end

-- `options` is an array of { label, onClick, color (optional {r,g,b}) }.
function CL.ShowDropdown(anchor, options)
    if not dropdownCatcher then
        dropdownCatcher = CreateFrame("Button", nil, UIParent)
        dropdownCatcher:SetAllPoints(UIParent)
        dropdownCatcher:SetFrameLevel(1)
        dropdownCatcher:EnableMouse(true)
        dropdownCatcher:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        dropdownCatcher:SetScript("OnClick", CL.CloseDropdown)
    end
    if not dropdownFrame then
        dropdownFrame = CreateFrame("Frame", nil, UIParent)
        -- Frame LEVEL (not strata - see below) one above the catcher,
        -- so the actual clickable rows win same-strata stacking order
        -- against the full-screen catcher sitting right underneath them.
        dropdownFrame:SetFrameLevel(2)
        dropdownFrame:SetBackdrop(CL.WINDOW_BACKDROP)
        dropdownFrame:SetBackdropColor(0.05, 0.05, 0.05, 0.97)
        dropdownFrame:SetBackdropBorderColor(CL.FLAT_BORDER_R, CL.FLAT_BORDER_G, CL.FLAT_BORDER_B, 1)
        dropdownFrame.rows = {}
    end

    -- Strata is recomputed on every open, one tier above whatever
    -- opened it right now (anchor's OWN current strata, not a fixed
    -- constant) - a submenu just needs to beat its own anchor, not
    -- unconditionally outrank every other addon's UI by sitting at the
    -- single topmost TOOLTIP tier regardless of context.
    local dropStrata = CL.NextHigherStrata(anchor:GetFrameStrata())
    dropdownCatcher:SetFrameStrata(dropStrata)
    dropdownFrame:SetFrameStrata(dropStrata)

    dropdownCatcher:Show()

    local ROW_H = 16
    local width = 150
    local count = table.getn(options)
    local height = count * ROW_H + 6
    dropdownFrame:SetWidth(width)
    dropdownFrame:SetHeight(height)
    dropdownFrame:ClearAllPoints()
    -- Opens upward instead when there isn't room below the anchor to
    -- fit without running off the bottom of the screen - meter windows
    -- commonly sit low on screen (a corner HUD), where a downward
    -- dropdown routinely got clipped/ran past the screen edge.
    local anchorBottom = anchor:GetBottom() or 0
    if anchorBottom - height < 10 then
        dropdownFrame:SetPoint("BOTTOM", anchor, "TOP", 0, 2)
    else
        dropdownFrame:SetPoint("TOP", anchor, "BOTTOM", 0, -2)
    end

    local i
    for i = 1, count do
        local row = dropdownFrame.rows[i]
        if not row then
            row = CreateFrame("Button", nil, dropdownFrame)
            row:SetHeight(ROW_H)
            row:EnableMouse(true)
            row:RegisterForClicks("LeftButtonUp")
            local hl = row:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints(row)
            hl:SetTexture("Interface\\Buttons\\WHITE8X8")
            hl:SetVertexColor(1, 1, 1, 0.15)
            local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            text:SetPoint("LEFT", row, "LEFT", 4, 0)
            text:SetJustifyH("LEFT")
            CL.ApplyFont(text)
            row.text = text
            dropdownFrame.rows[i] = row
        end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", dropdownFrame, "TOPLEFT", 3, -3 - (i - 1) * ROW_H)
        row:SetPoint("TOPRIGHT", dropdownFrame, "TOPRIGHT", -3, -3 - (i - 1) * ROW_H)
        row.text:SetText(options[i].label)
        -- Optional per-row color (e.g. Current/Overall in class color, to
        -- stand out from the plain-white History entries below them) -
        -- rows are pooled/reused, so reset to plain white when a row
        -- doesn't specify one rather than leaking a previous row's color.
        local color = options[i].color
        if color then
            row.text:SetTextColor(color[1], color[2], color[3])
        else
            row.text:SetTextColor(1, 1, 1)
        end
        local onClick = options[i].onClick
        row:SetScript("OnClick", function()
            CL.CloseDropdown()
            if onClick then onClick() end
        end)
        row:Show()
    end
    local j
    for j = count + 1, table.getn(dropdownFrame.rows) do
        dropdownFrame.rows[j]:Hide()
    end

    dropdownFrame:Show()
end

function CL.IsSmoothBars()
    local v = CL.GetSetting("smoothBars")
    if v == nil then return true end
    return v
end

function CL.GetBarSpeed()
    return CL.GetSetting("barSpeed") or 8
end

-- Repositions a pooled bar list (StatusBar frames anchored TOPLEFT/
-- TOPRIGHT to their own parent, stacked by index - the pattern every
-- bar pool in this addon uses) after a bar-height change, since each
-- bar's Y offset was computed from the height at creation time.
function CL.RepositionBarPool(pool, height, gap)
    local i
    for i = 1, table.getn(pool) do
        local bar = pool[i]
        bar:SetHeight(height)
        bar:ClearAllPoints()
        bar:SetPoint("TOPLEFT", bar:GetParent(), "TOPLEFT", 0, -((i - 1) * (height + gap)))
        bar:SetPoint("TOPRIGHT", bar:GetParent(), "TOPRIGHT", 0, -((i - 1) * (height + gap)))
    end
end

-- Number formatting - shared so every window's numbers change together
-- from one Options setting instead of each having its own baked-in
-- k/m-abbreviation logic.
CL.NUMBER_FORMATS = {
    { key = "abbreviated", label = "Abbreviated (1.2k)" },
    { key = "full", label = "Full (1,234)" },
    { key = "raw", label = "Raw (1234)" },
}

local function AddCommas(numStr)
    local formatted = numStr
    local k
    while true do
        formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", "%1,%2")
        if k == 0 then break end
    end
    return formatted
end

-- "253 DPS" instead of "253/s" - mode-aware (HPS for healing, DTPS for
-- damage taken) rather than blindly always saying DPS, since that would
-- be wrong while looking at Healing Done.
CL.RATE_SUFFIXES = { damage = "DPS", healing = "HPS", taken = "DTPS" }

function CL.RateSuffix(mode)
    return CL.RATE_SUFFIXES[mode] or "/s"
end

function CL.FormatNumber(n)
    n = n or 0
    if n < 0 then n = 0 end
    local mode = CL.GetSetting("numberFormat") or "abbreviated"
    if mode == "raw" then
        return tostring(math.floor(n))
    elseif mode == "full" then
        return AddCommas(tostring(math.floor(n)))
    end
    if n >= 1000000 then
        return string.format("%.1fm", n / 1000000)
    elseif n >= 1000 then
        return string.format("%.1fk", n / 1000)
    end
    return tostring(math.floor(n))
end

-- Appearance-changed pub/sub - each UI file registers a listener that
-- re-applies font/texture/bar-height/number-format to its own pooled
-- bars; Options fires this once after any change so every open window
-- updates immediately instead of needing a /reload.
CL.appearanceListeners = {}

function CL.OnAppearanceChanged(fn)
    table.insert(CL.appearanceListeners, fn)
end

function CL.FireAppearanceChanged()
    local i
    for i = 1, table.getn(CL.appearanceListeners) do
        local ok, err = pcall(CL.appearanceListeners[i])
        if not ok then
            CL.Print("Appearance listener error: " .. tostring(err))
        end
    end
end

-- Generic icon for melee entries (Auto Attack/Off-Hand have no spellId
-- to look an icon up from).
CL.MELEE_ICON = "Interface\\Icons\\Ability_MeleeDamage"

-- Texture coordinates for Interface\TargetingFrame\UI-Classes-Circle's
-- 4x3 class grid - a real Blizzard global (CLASS_ICON_TCOORDS) on most
-- client builds, but not guaranteed without pfUI's own fallback
-- definition of it, so this addon keeps its own copy rather than
-- depending on pfUI being installed. Standard, unchanging vanilla
-- values - no Death Knight/Monk/Demon Hunter/Evoker, those classes
-- don't exist yet.
CL.CLASS_ICON_TCOORDS = {
    WARRIOR = { 0, 0.25, 0, 0.25 },
    MAGE = { 0.25, 0.49609375, 0, 0.25 },
    ROGUE = { 0.49609375, 0.7421875, 0, 0.25 },
    DRUID = { 0.7421875, 0.98828125, 0, 0.25 },
    HUNTER = { 0, 0.25, 0.25, 0.5 },
    SHAMAN = { 0.25, 0.49609375, 0.25, 0.5 },
    PRIEST = { 0.49609375, 0.7421875, 0.25, 0.5 },
    WARLOCK = { 0.7421875, 0.98828125, 0.25, 0.5 },
    PALADIN = { 0, 0.25, 0.5, 0.75 },
}

-- spellId -> icon texture path. GetSpellRecField's "spellIconID" field
-- gives a numeric icon id, which GetSpellIconTexture resolves to a real
-- texture path - covers any spellId seen in combat, not just ones in
-- the player's own spellbook (GetSpellTexture only works for that,
-- useless for other units' abilities).
function CL.GetSpellIcon(spellId)
    if not spellId then return nil end
    if type(GetSpellRecField) ~= "function" or type(GetSpellIconTexture) ~= "function" then return nil end
    local okId, iconId = pcall(GetSpellRecField, spellId, "spellIconID")
    if not okId or not iconId or iconId <= 0 then return nil end
    local okTex, tex = pcall(GetSpellIconTexture, iconId)
    if okTex and type(tex) == "string" and tex ~= "" then
        return tex
    end
    return nil
end


-- WoW's own epic-quality purple hex, used for visual consistency with
-- the author's other addons.
CL.ACCENT_HEX = "a335ee"
CL.ACCENT_R, CL.ACCENT_G, CL.ACCENT_B = 0.64, 0.21, 0.93

-- Window chrome (borders, buttons, non-unit-specific titles) themes
-- itself to the player's own class color rather than the fixed purple
-- accent above - per-unit content (bars, breakdown/recap titles) still
-- colors by whichever unit it's showing, which is a different, correct
-- thing. Falls back to the purple accent if class lookup ever fails.
function CL.GetThemeColor()
    local ok, _, classToken = pcall(UnitClass, "player")
    if ok and classToken and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken] then
        local c = RAID_CLASS_COLORS[classToken]
        return c.r, c.g, c.b, string.format("%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
    end
    return CL.ACCENT_R, CL.ACCENT_G, CL.ACCENT_B, CL.ACCENT_HEX
end

-- "auto" resolves to whichever of these the player is actually in
-- (raid > party), falling back to Say if solo - chosen at announce time,
-- not stored, since group status can change between one announce and
-- the next.
CL.ANNOUNCE_CHANNELS = {
    { key = "auto", label = "Auto (raid/party)" },
    { key = "say", label = "Say" },
    { key = "party", label = "Party" },
    { key = "raid", label = "Raid" },
    { key = "guild", label = "Guild" },
}

function CL.ResolveAnnounceChannel()
    local key = CL.GetSetting("announceChannel") or "auto"
    if key == "auto" then
        if GetNumRaidMembers and GetNumRaidMembers() > 0 then return "RAID" end
        if GetNumPartyMembers and GetNumPartyMembers() > 0 then return "PARTY" end
        return "SAY"
    end
    return string.upper(key)
end

CL.MAX_ENCOUNTERS = 50 -- same trim-oldest cap pattern as LootLedger's MAX_HISTORY_ENTRIES

function CL.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff" .. CL.ACCENT_HEX .. "CombatLedger:|r " .. msg)
end

-- Debug event/aggregation logging, off by default - toggle with /cl
-- debug when troubleshooting. Goes to a file (LogLine/FlushLog), not
-- chat - see the file-header note.
CL.debug = false

-- Restoring CL.debug from CombatLedgerDB.settings.debug (persisted by
-- /cl debug - see Events.lua) so it's already on by the time
-- PLAYER_ENTERING_WORLD fires on the NEXT login - that event fires
-- before there's ever a chance to type /cl debug fresh each session,
-- which made login-time behavior (e.g. Threat.lua's version handshake)
-- structurally impossible to capture otherwise. Can't just read
-- CombatLedgerDB.settings.debug here at top-level like the line above -
-- this client restores SavedVariables from disk AFTER this file's own
-- init runs (see EnsureSettingsTable's comment below), so a synchronous
-- read here would always see the pre-restore default, never the real
-- saved value. Registered directly in Core.lua (the first file loaded,
-- per the .toc) specifically so this fires BEFORE any other file's own
-- PLAYER_ENTERING_WORLD handler that might check CL.debug on the same
-- event - Threat.lua in particular loads earlier than Events.lua and
-- fires on this same event too.
local debugRestoreFrame = CreateFrame("Frame")
debugRestoreFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
debugRestoreFrame:SetScript("OnEvent", function()
    CL.debug = (CombatLedgerDB.settings.debug == true)
end)

-- Session-only (not saved) - fills every meter window with fabricated
-- data so appearance settings can be previewed without needing to
-- actually fight something. See Aggregator.lua's GetTestEncounter and
-- UI_Options.lua's toggle.
CL.testMode = false

-- table.getn/pairs-based count - Lua 5.0 has no # operator.
function CL.TableCount(t)
    local n = 0
    local _
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- Lua 5.0 has no bitwise operators (and no guaranteed `bit` library on
-- this client) - checks whether a single power-of-two bit is set in
-- value by hand: floor(value/bit) mod 2 == 1. `bit` must itself be a
-- power of two (128, 16384, ...), not a combined mask.
function CL.HasBit(value, bit)
    if not value then return false end
    return math.mod(math.floor(value / bit), 2) == 1
end

-- AUTO_ATTACK_SELF/OTHER's hitInfo and SPELL_DAMAGE_EVENT_SELF/OTHER's
-- hitInfo are different bitfields, not the same convention reused -
-- 0x02 means "normal swing landed" (present on every auto-attack hit)
-- for the former, but means "critical hit" for the latter. The
-- auto-attack side matches the well-known MaNGOS/TrinityCore HITINFO_*
-- enum.
CL.AUTO_ATTACK_HITFLAG_CRIT = 128
CL.AUTO_ATTACK_HITFLAG_GLANCING = 16384
CL.AUTO_ATTACK_HITFLAG_CRUSHING = 32768
CL.AUTO_ATTACK_HITFLAG_OFFHAND = 4
CL.SPELL_DAMAGE_HITFLAG_CRIT = 2

-- dodge/parry/miss on this server do not arrive as separate
-- SPELL_MISS_* events - they arrive as a dmg=0 AUTO_ATTACK with one of
-- these victimState values instead. block/evade/immune/deflect are the
-- standard MaNGOS-family VICTIMSTATE_* values, kept here for forward
-- compatibility rather than folding them into "other".
CL.VICTIMSTATE_MISS = 0
CL.VICTIMSTATE_NORMAL = 1
CL.VICTIMSTATE_DODGE = 2
CL.VICTIMSTATE_PARRY = 3
CL.VICTIMSTATE_INTERRUPT = 4
CL.VICTIMSTATE_BLOCK = 5
CL.VICTIMSTATE_EVADE = 6
CL.VICTIMSTATE_IMMUNE = 7
CL.VICTIMSTATE_DEFLECT = 8

--------------------------------------------------------------------------
-- File-based debug log (WriteCustomFile, Nampower v3.2+)
--------------------------------------------------------------------------

CL.LOG_FILENAME = "CombatLedger_debug.log"

local logBuffer = {}
local loggedThisSession = false -- first flush of a session overwrites (fresh file per test), later ones append

-- LogLine buffers rather than writing immediately - combat events can
-- fire many times a second, and a WriteCustomFile call per line would be
-- a lot of disk I/O during a real fight. FlushLog (called periodically
-- from Events.lua's OnUpdate, and on the grace-window encounter-end)
-- batches the buffer into one write.
function CL.LogLine(line)
    table.insert(logBuffer, line)
end

function CL.FlushLog()
    if table.getn(logBuffer) == 0 then return end
    if not WriteCustomFile then return end

    local content = table.concat(logBuffer, "\n") .. "\n"
    local mode = loggedThisSession and "a" or "w"
    local ok = pcall(WriteCustomFile, CL.LOG_FILENAME, content, mode)
    if ok then
        loggedThisSession = true
        logBuffer = {}
    end
    -- on failure, leave the buffer intact and retry on the next flush
    -- rather than silently dropping data
end
