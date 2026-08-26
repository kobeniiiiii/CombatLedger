--[[
    UI_MainWindow - the live meter. Instantiable: "main" is always
    created (auto-shown, tied to /cl toggle, not closable), and Options
    can spawn additional independent windows (own frame/bars/mode/
    segment/layout) so someone can watch Damage in one window and
    Healing in another at the same time. Window state (frame/bars/
    lastShownCount) lives on a per-window `inst` table.

    Pooled StatusBar rows sized/positioned like GreedMeter's UI/Frames.lua
    (fixed bar pool, class-colored fill, dark bg texture, name/value
    FontStrings) and window chrome (backdrop, drag-move, resize grip,
    pfUI skin pass) like LootLedger's CreateLootWindow - same visual
    language, not shared code.

    Mode/segment controls are simple click-to-cycle buttons rather than
    a dropdown menu - keeps the UI simple with a fraction of the code a
    full UIDropDownMenu would need.
]]

local CL = CombatLedger
local UI = {}
CL.UI = UI

local MAX_BARS = 20
local BAR_HEIGHT = 18
local BAR_GAP = 2
local HEADER_HEIGHT = 28 -- a few extra px of breathing room below the button row before the first bar
local FOOTER_GAP = 12

-- Caps the hover tooltip's "By target:"/"By spell:" lists (see
-- ShowBarTooltip) - Overall mode never resets on its own and can rack up
-- a target list running well past screen height over a long session,
-- pushing the spell breakdown off-screen entirely. Full uncapped detail
-- is still one click away via the Breakdown window.
local TOOLTIP_TARGET_LIST_CAP = 5

local WINDOW_WIDTH, WINDOW_HEIGHT = 220, 260
local MIN_WINDOW_WIDTH, MIN_WINDOW_HEIGHT = 160, 100
local MAX_WINDOW_WIDTH, MAX_WINDOW_HEIGHT = 500, 600

local REFRESH_INTERVAL = 0.2

-- "Buffs Given" was built (same mechanism as Debuffs) but is hidden -
-- prebuffing happens out of combat, before the encounter it's for even
-- starts, so it doesn't fit this addon's per-encounter model. See
-- Aggregator.lua.
-- Threat is last, matching GreedMeter's own ordering - and unlike every
-- other mode, it isn't built from anything CombatLedger aggregates
-- itself. It's a live snapshot from this server's own threat API (see
-- Threat.lua) with no Current/Overall/History distinction, so it gets
-- its own code path through RefreshInstance/ShowBarTooltip below rather
-- than flowing through GetActiveEncounter like everything else.
local MODE_ORDER = { "damage", "healing", "taken", "cleanses", "debuffs", "interrupts", "deaths", "threat" }
local MODE_TITLES = { damage = "Damage Done", healing = "Healing Done", taken = "Damage Taken", cleanses = "Dispels", debuffs = "Debuffs Given", interrupts = "Interrupts", deaths = "Deaths", threat = "Threat" }

-- Cleanses/Debuffs/Interrupts are counts, not amounts - no meaningful
-- "rate" or "crit %" the way damage/healing have, so bars/tooltips/
-- announce show a plain count for these instead.
local COUNT_ONLY_MODES = { cleanses = true, debuffs = true, interrupts = true }
local COUNT_WORD = { cleanses = "dispel", debuffs = "debuff", interrupts = "interrupt" }

local function CountLabel(mode, n)
    local word = COUNT_WORD[mode] or "event"
    return n .. " " .. word .. ((n == 1) and "" or "s")
end

-- Full words now that these show directly on the header buttons instead
-- of a separate title (see the header-row comment near CreateWindowFrame) -
-- "history" is only ever a fallback default; the real text once a
-- specific saved encounter is selected is that encounter's own label
-- (see ShowHistoryEncounterIn).
local SEGMENT_LABELS = { current = "Current", overall = "Overall", history = "History" }

-- Every open window, keyed by id. "main" always exists; extra windows
-- (from Options' "New Window" button) get ids like "window2", "window3",
-- ... CL.UIWindows exposes this to UI_Options.lua for the window list.
local instances = {}
local instanceOrder = {}
CL.UIWindows = instances

-- Set right before StaticPopup_Show("COMBATLEDGER_ANNOUNCE") and read
-- from its OnAccept - a plain captured variable rather than relying on
-- StaticPopup_Show's own data-passing arguments, whose exact behavior
-- on this client build isn't worth depending on for something this
-- simple.
local pendingAnnounceInst = nil

-- Dropdown menu itself (CL.ShowDropdown/CL.CloseDropdown) moved to
-- Core.lua so UI_Options.lua can use the same one for its Bar texture/
-- Font/Number format pickers instead of duplicating it.

local function FormatNumber(n)
    return CL.FormatNumber(n)
end

local function ClassColor(classToken)
    if classToken and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken] then
        local c = RAID_CLASS_COLORS[classToken]
        return c.r, c.g, c.b
    end
    return 0.6, 0.6, 0.6
end

-- {r, g, b} table form, for the segment dropdown's Current/Overall rows
-- (see ShowDropdown's `color` option field) - makes those two stand out
-- in class color from the plain-white History entries below them.
local function PlayerClassColorTable()
    local ok, _, classToken = pcall(UnitClass, "player")
    local r, g, b = ClassColor(ok and classToken or nil)
    return { r, g, b }
end

local function MetricTotal(u, mode)
    if mode == "healing" then
        return (u.healingDone and u.healingDone.total) or 0
    elseif mode == "taken" then
        return (u.damageTaken and u.damageTaken.total) or 0
    elseif mode == "cleanses" then
        return (u.cleanses and u.cleanses.total) or 0
    elseif mode == "debuffs" then
        return (u.debuffsGiven and u.debuffsGiven.total) or 0
    elseif mode == "interrupts" then
        return (u.interrupts and u.interrupts.total) or 0
    elseif mode == "deaths" then
        return u.deaths or 0
    end
    return (u.damageDone and u.damageDone.total) or 0
end

local function BuildSortedList(units, mode)
    local list = {}
    local guid, u
    for guid, u in pairs(units) do
        local val = MetricTotal(u, mode)
        if val > 0 then
            table.insert(list, { guid = guid, name = u.name, classToken = u.classToken, total = val })
        end
    end
    table.sort(list, function(a, b) return a.total > b.total end)
    return list
end

-- Threat mode's own list builder - CL.Threat.GetSnapshot() is already a
-- flat [guid]={name,threat,perc,melee,tank} table refreshed live by the
-- server (see Threat.lua), not something built up from recorded events
-- the way every other mode's list is, so this doesn't go through
-- MetricTotal/units at all. classToken comes from GuidCache since threat
-- entries are always real roster members (a real guid, not a synthetic
-- one) whenever the roster scan managed to resolve them. `filterSet`
-- ([name]=true) narrows the list to just those names - see
-- ShowThreatFilterDropdown; nil/empty shows everyone.
-- Second return value is the "Pull Aggro At" reference row (mirrors
-- TWThreat's own calcAGROPerc) - not a real player, so it's kept
-- separate from the sorted list rather than mixed in, letting
-- RefreshInstance compute bar-width scaling from real entries only
-- before pinning this to the top. Vanilla's threat-override rule: a
-- non-tank needs more than 130% of the tank's threat to pull aggro at
-- range, 110% in melee - the value shown is how much MORE threat you
-- specifically still need, not the raw threshold.
local function BuildThreatList(filterSet)
    local list = {}
    -- Test Mode substitutes a fake snapshot (see Threat.lua's
    -- GetTestSnapshot) so Threat mode previews with dummy bars + the
    -- Pull Aggro At marker below, same as every other mode already did.
    local snapshot = CL.testMode and CL.Threat and CL.Threat.GetTestSnapshot and CL.Threat.GetTestSnapshot()
        or (CL.Threat and CL.Threat.GetSnapshot())
    if not snapshot then return list, nil end
    local hasFilter = filterSet and next(filterSet) ~= nil
    local playerName = UnitName("player")
    local tankThreat, playerMelee
    local guid, t
    for guid, t in pairs(snapshot) do
        if not hasFilter or filterSet[t.name] then
            -- Test entries carry their own classToken directly (fake
            -- guids have nothing for GuidCache to resolve); real ones
            -- still resolve through the roster cache as before.
            local classToken = t.classToken
            if not classToken and CL.GuidCache then
                local info = CL.GuidCache.Resolve(guid)
                classToken = info and info.classToken
            end
            table.insert(list, {
                guid = guid,
                name = t.name,
                classToken = classToken,
                total = t.threat,
                perc = t.perc,
                melee = t.melee,
                tank = t.tank,
            })
        end
        if t.tank then tankThreat = t.threat end
        if t.name == playerName then playerMelee = t.melee end
    end
    table.sort(list, function(a, b) return a.total > b.total end)

    local marker = nil
    if tankThreat and tankThreat > 0 then
        local threshold = tankThreat * (playerMelee and 1.1 or 1.3)
        marker = {
            guid = "THREAT_AGRO_MARKER",
            name = "Pull Aggro At",
            total = threshold - tankThreat,
            isAgroMarker = true,
        }
    end

    return list, marker
end

-- Same list either mode uses: melee + petMelee + each spell, sorted
-- descending. Reused by the hover tooltip below (GreedMeter shows this
-- exact "By spell" breakdown on mouseover rather than requiring a click).
local function BuildSpellSummary(u, mode)
    local list = {}
    if not u then return list end
    local bucket
    if mode == "healing" then
        bucket = u.healingDone
    elseif mode == "taken" then
        bucket = u.damageTaken
    elseif mode == "cleanses" then
        bucket = u.cleanses
    elseif mode == "debuffs" then
        bucket = u.debuffsGiven
    elseif mode == "interrupts" then
        bucket = u.interrupts
    else
        bucket = u.damageDone
    end
    if not bucket then return list end

    if bucket.melee and bucket.melee.total and bucket.melee.total > 0 then
        table.insert(list, { name = "Auto Attack", total = bucket.melee.total })
    end
    if bucket.offhand and bucket.offhand.total and bucket.offhand.total > 0 then
        table.insert(list, { name = "Off-Hand", total = bucket.offhand.total })
    end
    if bucket.petMelee and bucket.petMelee.total and bucket.petMelee.total > 0 then
        table.insert(list, { name = "Pet Auto Attack", total = bucket.petMelee.total })
    end
    if bucket.petOffhand and bucket.petOffhand.total and bucket.petOffhand.total > 0 then
        table.insert(list, { name = "Pet Off-Hand", total = bucket.petOffhand.total })
    end
    if bucket.spells then
        local spellId, s
        for spellId, s in pairs(bucket.spells) do
            table.insert(list, { name = s.name or ("Spell " .. tostring(spellId)), total = s.total })
        end
    end
    table.sort(list, function(a, b) return a.total > b.total end)
    return list
end

-- Who this player's damage/healing/etc actually landed on, same data
-- the breakdown window's per-target list uses.
local function BuildTargetSummary(u, mode)
    local list = {}
    local bucket
    if mode == "healing" then
        bucket = u and u.healingDone
    elseif mode == "taken" then
        bucket = u and u.damageTaken
    elseif mode == "cleanses" then
        bucket = u and u.cleanses
    elseif mode == "debuffs" then
        bucket = u and u.debuffsGiven
    elseif mode == "interrupts" then
        bucket = u and u.interrupts
    else
        bucket = u and u.damageDone
    end
    if not bucket or not bucket.targets then return list end
    local guid, t
    for guid, t in pairs(bucket.targets) do
        table.insert(list, { name = t.name, total = t.total })
    end
    table.sort(list, function(a, b) return a.total > b.total end)
    return list
end

-- Deaths mode: what actually killed them, not a rate - reuses the same
-- recap buffer the dedicated Death Recap window snapshots on UNIT_DIED
-- (see Aggregator.lua). Only the live current/overall segments have a
-- recap available (it's not saved into history), so a saved encounter's
-- Deaths tab just shows the count with no further detail.
local function ShowDeathTooltip(bar, u)
    GameTooltip:SetOwner(bar, "ANCHOR_RIGHT")
    GameTooltip:AddLine(u.name, ClassColor(u.classToken))
    GameTooltip:AddDoubleLine("Deaths", tostring(u.deaths or 0), 1, 1, 1, 1, 1, 1)

    local recap = CL.Aggregator.GetDeathRecap(bar.guid)
    local hits = recap and recap.hits
    if hits and table.getn(hits) > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Last death (most recent first):", 1, 0.82, 0)
        local n = table.getn(hits)
        local shown = 0
        local i
        for i = n, 1, -1 do
            if shown >= 6 then break end
            shown = shown + 1
            local h = hits[i]
            local label = (shown == 1) and ("Killing blow: " .. h.attacker .. " (" .. h.label .. ")")
                or (h.attacker .. " (" .. h.label .. ")")
            GameTooltip:AddDoubleLine(label, FormatNumber(h.amount) .. (h.isCrit and " CRIT" or ""),
                0.9, 0.9, 0.9, 1, 1, 1)
        end
    else
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("No hit history recorded for this death", 0.6, 0.6, 0.6)
    end

    GameTooltip:Show()
end

-- The actual encounter object behind whatever segment this window has
-- selected - current/overall/history all resolve through here so
-- Refresh, the tooltip, Announce, and the breakdown window don't each
-- need their own copy of this branching.
local function GetActiveEncounter(inst)
    if CL.testMode then
        return CL.Aggregator.GetTestEncounter()
    end
    local f = inst.frame
    if f.segment == "overall" then
        return CL.Aggregator.GetOverall()
    elseif f.segment == "history" then
        return f.historyEncounter
    end
    return CL.Aggregator.GetCurrentDisplay()
end

local function ShowBarTooltip(inst, bar)
    if not bar.guid then return end

    if inst.frame.mode == "threat" then
        local snapshot = CL.Threat and CL.Threat.GetSnapshot()
        local t = snapshot and snapshot[bar.guid]
        if not t then return end
        local info = CL.GuidCache and CL.GuidCache.Resolve(bar.guid)
        GameTooltip:SetOwner(bar, "ANCHOR_RIGHT")
        GameTooltip:AddLine(t.name, ClassColor(info and info.classToken))
        GameTooltip:AddDoubleLine("Threat", FormatNumber(t.threat), 1, 1, 1, 1, 1, 1)
        GameTooltip:AddDoubleLine("% of Tank", t.perc .. "%", 1, 1, 1, 1, 1, 1)
        if t.melee then
            GameTooltip:AddLine("In melee range", 0.7, 0.7, 0.7)
        end
        if t.tank then
            GameTooltip:AddLine("Currently tanking", 1, 0.82, 0)
        end
        GameTooltip:Show()
        return
    end

    local enc = GetActiveEncounter(inst)
    local u = enc and enc.units and enc.units[bar.guid]
    if not u then return end

    local mode = inst.frame.mode

    if mode == "deaths" then
        ShowDeathTooltip(bar, u)
        return
    end

    local total = MetricTotal(u, mode)

    local duration = 1
    if inst.frame.segment == "overall" then
        duration = CL.Aggregator.GetOverallDuration()
    elseif enc then
        duration = (enc.duration and enc.duration > 0) and enc.duration or (GetTime() - enc.startTime)
    end
    if duration <= 0 then duration = 1 end

    GameTooltip:SetOwner(bar, "ANCHOR_RIGHT")
    GameTooltip:AddLine(u.name, ClassColor(u.classToken))
    if COUNT_ONLY_MODES[mode] then
        GameTooltip:AddDoubleLine(MODE_TITLES[mode] or "Total", CountLabel(mode, total), 1, 1, 1, 1, 1, 1)
    else
        GameTooltip:AddDoubleLine(MODE_TITLES[mode] or "Total", FormatNumber(total), 1, 1, 1, 1, 1, 1)
        GameTooltip:AddDoubleLine("Rate", FormatNumber(total / duration) .. " " .. CL.RateSuffix(mode), 1, 1, 1, 1, 1, 1)
    end
    GameTooltip:AddDoubleLine("Duration", string.format("%.1fs", duration), 1, 1, 1, 1, 1, 1)

    if mode == "damage" or mode == "taken" then
        local bucket = (mode == "taken") and u.damageTaken or u.damageDone
        if bucket then
            local sum = { miss = 0, dodge = 0, parry = 0, block = 0, evade = 0, immune = 0, deflect = 0, other = 0 }
            local hits = 0
            local entry
            for _, entry in ipairs({ bucket.melee, bucket.offhand, bucket.petMelee, bucket.petOffhand }) do
                if entry then
                    hits = hits + (entry.hits or 0)
                    if entry.avoided then
                        local k, v
                        for k, v in pairs(entry.avoided) do
                            sum[k] = (sum[k] or 0) + v
                        end
                    end
                end
            end
            local avoided = sum.miss + sum.dodge + sum.parry + sum.block + sum.evade + sum.immune + sum.deflect + sum.other
            local swings = hits + avoided
            if swings > 0 then
                local parts = {}
                if sum.dodge > 0 then table.insert(parts, sum.dodge .. " dodge") end
                if sum.parry > 0 then table.insert(parts, sum.parry .. " parry") end
                if sum.miss > 0 then table.insert(parts, sum.miss .. " miss") end
                if sum.block > 0 then table.insert(parts, sum.block .. " block") end
                if sum.evade > 0 then table.insert(parts, sum.evade .. " evade") end
                if sum.immune > 0 then table.insert(parts, sum.immune .. " immune") end
                if sum.deflect > 0 then table.insert(parts, sum.deflect .. " deflect") end
                if sum.other > 0 then table.insert(parts, sum.other .. " other") end
                local label = (mode == "taken") and "Avoided" or "Swings missed"
                GameTooltip:AddDoubleLine(label,
                    string.format("%d/%d (%.0f%%)", avoided, swings, (avoided / swings) * 100), 1, 1, 1, 1, 1, 1)
                if table.getn(parts) > 0 then
                    GameTooltip:AddLine(table.concat(parts, ", "), 0.7, 0.7, 0.7)
                end
            end
        end
    end

    do
        local targets = BuildTargetSummary(u, mode)
        if table.getn(targets) > 0 then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("By target:", 1, 0.82, 0)
            local i
            local shown = table.getn(targets)
            if shown > TOOLTIP_TARGET_LIST_CAP then shown = TOOLTIP_TARGET_LIST_CAP end
            for i = 1, shown do
                GameTooltip:AddDoubleLine(targets[i].name, FormatNumber(targets[i].total), 0.9, 0.9, 0.9, 1, 1, 1)
            end
            -- Overall never resets on its own (only /cl reset or the
            -- clear-on-join option) - after a long session it can rack up
            -- a target list running well past screen height, which used
            -- to push the "By spell:" section (usually the more useful
            -- half) off-screen entirely. Sorted descending already (see
            -- BuildTargetSummary), so capping never hides the biggest
            -- entries - only a "+N more" summary line for the tail. Spells
            -- stay uncapped - that list is naturally short and is the
            -- part actually worth seeing at a glance.
            local remaining = table.getn(targets) - shown
            if remaining > 0 then
                GameTooltip:AddLine("+" .. remaining .. " more - click for full breakdown", 0.6, 0.6, 0.6)
            end
        end
    end

    local spells = BuildSpellSummary(u, mode)
    if table.getn(spells) > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("By spell:", 1, 0.82, 0)
        local i
        for i = 1, table.getn(spells) do
            local pct = (total > 0) and (spells[i].total / total * 100) or 0
            GameTooltip:AddDoubleLine(spells[i].name,
                FormatNumber(spells[i].total) .. " (" .. string.format("%.1f", pct) .. "%)", 0.9, 0.9, 0.9, 1, 1, 1)
        end
    end

    GameTooltip:Show()
end

local function CreateBar(inst, parent, index)
    local height = CL.GetBarHeight(BAR_HEIGHT)
    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetHeight(height)
    bar:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -((index - 1) * (height + BAR_GAP)))
    bar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -((index - 1) * (height + BAR_GAP)))
    bar:SetStatusBarTexture(CL.GetBarTexture())
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    bar:SetStatusBarColor(0.6, 0.6, 0.6, 0.9)

    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(bar)
    bg:SetTexture(CL.GetBarTexture())
    bg:SetVertexColor(0.15, 0.15, 0.15, 0.85)
    bar.bg = bg

    -- Border overlay (Options: "Show bar border" / "Highlight my bar") -
    -- a SEPARATE child frame, not a backdrop set directly on bar itself.
    -- A plain SetBackdrop border on a StatusBar renders on the frame's
    -- own BACKGROUND layer, same as bar.bg above and the status-bar fill
    -- texture itself - whichever of those draws last/on top hides most
    -- of the border, leaving only a sliver visible wherever nothing
    -- happens to cover it (confirmed via screenshot: only the small
    -- unfilled strip near valueText showed any color). A child frame
    -- with a higher FrameLevel composites strictly above everything on
    -- bar, so the border is always fully visible regardless of fill %.
    local borderFrame = CreateFrame("Frame", nil, bar)
    borderFrame:SetAllPoints(bar)
    borderFrame:SetFrameLevel(bar:GetFrameLevel() + 10)
    borderFrame:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1,
        insets = { left = -1, right = -1, top = -1, bottom = -1 },
    })
    borderFrame:SetBackdropBorderColor(1, 1, 1, 0)
    bar.borderFrame = borderFrame

    -- Class icon slot - off by default (Options: "Show class icon"),
    -- hidden and unanchored until RefreshInstance decides per-refresh
    -- whether to show it. When it's off, nameText sits exactly where it
    -- always has (bar:LEFT+4) - no permanently-reserved gap for people
    -- who never turn this on.
    local classIcon = bar:CreateTexture(nil, "OVERLAY")
    classIcon:SetWidth(height - 4)
    classIcon:SetHeight(height - 4)
    classIcon:SetPoint("LEFT", bar, "LEFT", 3, 0)
    -- Not the stock Interface\TargetingFrame\UI-Classes-Circle atlas -
    -- confirmed (via /cl debug) that texture shows nothing on this
    -- client despite loading and rendering without error, same "non-
    -- square textures silently fail" class of issue as CL.GetBarTexture
    -- earlier, except this stock one apparently fails regardless of its
    -- real dimensions. Using pfUI's own bundled classicons.tga instead
    -- (256x256, confirmed square, MIT-licensed - see README) - same
    -- CLASS_ICON_TCOORDS layout, just a different, working file.
    classIcon:SetTexture("Interface\\AddOns\\CombatLedger\\img\\classicons")
    classIcon:Hide()
    bar.classIcon = classIcon

    local valueText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    valueText:SetPoint("RIGHT", bar, "RIGHT", -4, 0)
    valueText:SetJustifyH("RIGHT")
    valueText:SetText("")
    CL.ApplyFont(valueText, CL.GetFontSize())
    bar.valueText = valueText

    -- LEFT anchor is re-set every refresh (see RefreshInstance) based on
    -- whether the class icon is actually showing for this entry - starts
    -- at the same bar:LEFT+4 as always here. RIGHT is bounded to
    -- valueText (was unbounded) - an unbounded name could run straight
    -- into it once both were long enough. Created after valueText so it
    -- can anchor off it.
    local nameText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    nameText:SetPoint("LEFT", bar, "LEFT", 4, 0)
    nameText:SetPoint("RIGHT", valueText, "LEFT", -4, 0)
    nameText:SetJustifyH("LEFT")
    nameText:SetText("")
    CL.ApplyFont(nameText, CL.GetFontSize())
    bar.nameText = nameText

    bar:EnableMouse(true)
    bar:SetScript("OnMouseUp", function()
        -- No breakdown data exists for Threat (see Threat.lua) - it's a
        -- live server snapshot, not something recorded per-ability.
        if bar.guid and CL.UIBreakdown and inst.frame.mode ~= "threat" then
            CL.UIBreakdown.Show(bar.guid, inst.frame.mode, inst.frame.segment, inst.frame.historyEncounter)
        end
    end)
    bar:SetScript("OnEnter", function() ShowBarTooltip(inst, bar) end)
    bar:SetScript("OnLeave", function() GameTooltip:Hide() end)

    bar.targetPct = 0
    bar:Hide()
    return bar
end

-- The resize grip only takes up room when it's actually shown - locked
-- (grip hidden) reclaims that space for bars instead of leaving it
-- empty below the last one.
local function FooterGap()
    if CL.GetSetting("lockWindow") then return 4 end
    return FOOTER_GAP
end

-- How far the bar list can actually scroll. Deliberately NOT
-- barScroll:GetVerticalScrollRange() - that depends on the ScrollFrame's
-- own anchor-derived height, and this client doesn't reliably keep that
-- current (same class of geometry staleness as the breakdown window's
-- target-list layout, which works around it the same way: compute from
-- window:GetHeight(), a value that's directly SetHeight'd rather than
-- anchor-derived, instead of trusting a read-back that may be stale).
local function GetMaxBarScroll(window)
    local viewportHeight = window:GetHeight() - HEADER_HEIGHT - FooterGap()
    local maxScroll = window.barParent:GetHeight() - viewportHeight
    if maxScroll < 0 then maxScroll = 0 end
    return maxScroll
end

local RefreshInstance -- forward-declared, assigned below
local ShowThreatFilterDropdown -- forward-declared, assigned below

local function CreateHeaderButton(parent, width, initialText)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetWidth(width)
    btn:SetHeight(16)
    -- Flat WHITE8X8 shape, matching the window's own backdrop (see
    -- CL.WINDOW_BACKDROP) - used to be Blizzard's rounded Tooltip
    -- border, which stayed even after ApplyButtonSkin started recoloring
    -- the border to the new near-black flat color, since ApplyButtonSkin
    -- only ever recolors whatever backdrop shape was already set here -
    -- it never looked right mixed with the flat window frame around it.
    btn:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8", tile = false, tileSize = 0,
        edgeFile = "Interface\\BUTTONS\\WHITE8X8", edgeSize = 1,
        insets = { left = -1, right = -1, top = -1, bottom = -1 },
    })
    btn:SetBackdropColor(0.12, 0.12, 0.14, 0.9)
    btn:SetBackdropBorderColor(0.55, 0.55, 0.55, 1)

    -- Subtle raised-button sheen (no Blizzard button art dependency) so
    -- this reads as an actual button rather than a flat tinted box when
    -- pfUI isn't skinning it.
    local sheen = btn:CreateTexture(nil, "ARTWORK")
    sheen:SetPoint("TOPLEFT", btn, "TOPLEFT", 2, -2)
    sheen:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -2, 2)
    sheen:SetTexture("Interface\\Buttons\\WHITE8X8")
    if sheen.SetGradientAlpha then
        sheen:SetGradientAlpha("VERTICAL", 1, 1, 1, 0.12, 1, 1, 1, 0)
    else
        sheen:SetVertexColor(1, 1, 1, 0.06)
    end

    -- Click feedback (darkens briefly on press) - a plain backdrop box
    -- otherwise gives zero visual response to a click, part of why it
    -- reads as "off" without pfUI's own button skin doing this for us.
    -- OnMouseUp gives the snappy revert when it fires, but it's NOT
    -- reliable on this client once the click opens a dropdown/popup/new
    -- window mid-interaction (confirmed - R/O/! don't even open anything
    -- and still stuck) - btn.pressedAt is a safety net SetButtonTooltip's
    -- OnUpdate polls to force the revert even if OnMouseUp never comes.
    btn:SetScript("OnMouseDown", function()
        btn.pressedAt = GetTime()
        btn:SetBackdropColor(0.05, 0.05, 0.06, 0.9)
    end)
    btn:SetScript("OnMouseUp", function()
        btn.pressedAt = nil
        local fr, fg, fb, fa = CL.GetButtonNormalFill()
        btn:SetBackdropColor(fr, fg, fb, fa)
    end)

    local label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetAllPoints(btn)
    label:SetJustifyH("CENTER")
    label:SetText(initialText or "")
    CL.ApplyFont(label)
    btn.label = label
    return btn
end

-- Sets a CreateHeaderButton's label text and resizes the button to fit
-- it (label is SetAllPoints to the button, so resizing the button
-- resizes it) - used by modeBtn/segBtn now that they show full words
-- ("Damage Done", "Overall", a saved encounter's name) instead of a
-- fixed-width letter code.
--
-- Width comes from ComputeHeaderButtonWidths(parent's CURRENT width),
-- not from the text itself - Overall/Current/a long encounter name all
-- get the SAME width at a given window size, which is what stops the
-- button jumping around on every label change. That width isn't a fixed
-- constant either, though - it shrinks along with the window (see the
-- resize grip's OnUpdate, which reflows both buttons live on every
-- drag tick) so the window can still be dragged down small instead of
-- being floored at whatever width the full-word buttons prefer.
--
-- Text that doesn't fit the resulting width gets truncated with "..."
-- rather than just capping the button's own width and leaving the
-- label to render past it - a CENTER-justified FontString isn't
-- clipped by its own frame in vanilla, so an oversized string bled
-- visually into whatever button sat next to it instead of just getting
-- cut off at its own edge. btn.fullText/btn.isSegBtn remember the
-- untruncated text and role so a later reflow (font-size change, window
-- resize) can re-run this from the real original text instead of
-- re-truncating an already-truncated one.
local SEG_BTN_PREFERRED, MODE_BTN_PREFERRED = 90, 100
local HEADER_BTN_MIN_WIDTH = 20
-- Space the left button group (margin + R/!) actually occupies, plus
-- breathing room before Mode/Segment start - see CreateWindowFrame's
-- real anchor math (resetBtn/announceBtn) for what this approximates.
local HEADER_LEFT_GROUP_WIDTH = 46
local HEADER_RIGHT_PADDING = 20

local function ComputeHeaderButtonWidths(windowWidth)
    local preferredTotal = SEG_BTN_PREFERRED + MODE_BTN_PREFERRED
    local available = (windowWidth or 0) - HEADER_LEFT_GROUP_WIDTH - HEADER_RIGHT_PADDING
    if available >= preferredTotal then
        return SEG_BTN_PREFERRED, MODE_BTN_PREFERRED
    end
    if available < HEADER_BTN_MIN_WIDTH * 2 then
        available = HEADER_BTN_MIN_WIDTH * 2
    end
    return available * (SEG_BTN_PREFERRED / preferredTotal), available * (MODE_BTN_PREFERRED / preferredTotal)
end

local function SetHeaderButtonText(btn, text, isSegBtn)
    btn.fullText = text
    btn.isSegBtn = isSegBtn
    btn.label:SetText(text)
    local parent = btn:GetParent()
    local segW, modeW = ComputeHeaderButtonWidths(parent and parent:GetWidth())
    local w = isSegBtn and segW or modeW
    local target = w - 12
    if btn.label:GetStringWidth() > target then
        local truncated = text
        while string.len(truncated) > 1 and btn.label:GetStringWidth() > target do
            truncated = string.sub(truncated, 1, string.len(truncated) - 1)
            btn.label:SetText(truncated .. "...")
        end
    end
    btn:SetWidth(w)
end

-- Re-runs SetHeaderButtonText from the remembered original text/role -
-- for RestyleAll's font-size-change refresh and the resize grip's live
-- drag, where the button's available width may have changed without
-- the underlying text changing.
local function ReflowHeaderButton(btn)
    if btn.fullText then
        SetHeaderButtonText(btn, btn.fullText, btn.isSegBtn)
    end
end

-- Re-applies texture/font/height to every pooled bar in every open
-- window after an Options change, and repositions each pool (bar
-- Y-offsets were computed from the height at creation time).
local function RestyleAll()
    local id, inst
    for id, inst in pairs(instances) do
        local window = inst.frame
        if window then
            if CL.GetSetting("lockWindow") then
                window.resizeGrip:Hide()
            else
                window.resizeGrip:Show()
            end
            window.barScroll:ClearAllPoints()
            window.barScroll:SetPoint("TOPLEFT", window, "TOPLEFT", 6, -HEADER_HEIGHT)
            window.barScroll:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -6, FooterGap())
            window.barParent:SetWidth(window:GetWidth() - 12)
            -- Height is sized to the actual shown count, not the full
            -- MAX_BARS pool (see RefreshInstance) - invalidate the
            -- cached count so the refresh below recomputes it for the
            -- new bar height instead of leaving it at a stale size.
            inst.lastShownCount = -1
            local themeR, themeG, themeB = CL.GetThemeColor()
            CL.ApplyWindowSkin(window, themeR, themeG, themeB, 0.8)
            CL.ApplyButtonSkin(window.resetBtn, themeR, themeG, themeB)
            CL.ApplyButtonSkin(window.announceBtn, themeR, themeG, themeB)
            CL.ApplyButtonSkin(window.segBtn, themeR, themeG, themeB)
            CL.ApplyButtonSkin(window.modeBtn, themeR, themeG, themeB)
            CL.ApplyFont(window.resetBtn.label)
            CL.ApplyFont(window.announceBtn.label)
            CL.ApplyFont(window.segBtn.label)
            CL.ApplyFont(window.modeBtn.label)
            -- A font change can change these labels' rendered width too
            -- (they show full words now, not a fixed letter code) - keep
            -- them properly fit, not just re-fit at the next mode/segment
            -- switch.
            ReflowHeaderButton(window.segBtn)
            ReflowHeaderButton(window.modeBtn)
            local newBarHeight = CL.GetBarHeight(BAR_HEIGHT)
            CL.RepositionBarPool(inst.bars, newBarHeight, BAR_GAP)
            local i
            for i = 1, table.getn(inst.bars) do
                local bar = inst.bars[i]
                bar:SetStatusBarTexture(CL.GetBarTexture())
                bar.bg:SetTexture(CL.GetBarTexture())
                CL.ApplyFont(bar.nameText, CL.GetFontSize())
                CL.ApplyFont(bar.valueText, CL.GetFontSize())
                -- Class icon was sized once at bar creation from
                -- whatever the bar height was then - never followed a
                -- later "Bar size" change, so it stayed a fixed size
                -- while the bar around it grew/shrank.
                bar.classIcon:SetWidth(newBarHeight - 4)
                bar.classIcon:SetHeight(newBarHeight - 4)
            end
            RefreshInstance(inst)
        end
    end
    -- Dropdown row fonts aren't refreshed here - CL.ShowDropdown (Core.lua)
    -- already re-applies CL.ApplyFont to every row's text each time it
    -- opens, so there's nothing stale to catch up on a pure appearance
    -- change while it's closed.
end
CL.OnAppearanceChanged(RestyleAll)

-- restR/G/B (optional) is the button's normal border color - if given,
-- hovering brightens the border to white and leaving restores it. This
-- OWNS hover unconditionally now, including while matching pfUI - see
-- CL.ApplyButtonSkin, which passes disableHighlight=true to pfUI's own
-- SkinButton specifically so IT never installs a second, independent
-- OnEnter/OnLeave hover hook on these buttons that would otherwise
-- fight over the same border. That pfUI-owned hook was the real source
-- of the click/hover-stuck-color bug surviving past the first fix below
-- - it's built on the same raw OnEnter/OnLeave events already proven
-- unreliable here, and it was still fully enabled/wired up whenever
-- Match pfUI was on (the default), regardless of anything this function
-- did on its own side.
--
-- alwaysRestR/G/B (optional) - when given, hover-leave restores to
-- exactly this color unconditionally, ignoring both "Match pfUI" and
-- "Class colored menus". For a fixed-color button (nothing currently
-- uses this, but Reset used to) that shouldn't follow either setting
-- the way every other button's border does.
--
-- Driven entirely off an OnUpdate poll of MouseIsOver rather than
-- OnEnter/OnLeave (and CreateHeaderButton's press-color off a polled
-- btn.pressedAt timeout rather than trusting OnMouseUp) - confirmed on
-- this client that a click opening a dropdown/popup/new window can
-- swallow the matching Up/Leave event, leaving the button stuck
-- pressed-dark or hover-white. Polling every frame is immune to that
-- since it doesn't depend on any event actually being delivered - and
-- unlike the old timeout-only revert, the fill color below is now
-- CONTINUOUSLY re-asserted every frame whenever not pressed (not just
-- once, 0.15s after a click), so nothing can leave one button showing a
-- different tone than its never-yet-clicked neighbors and have it stick.
local function SetButtonTooltip(btn, title, subtitle, restR, restG, restB, alwaysRestR, alwaysRestG, alwaysRestB)
    local function NormalBorderColor()
        if alwaysRestR then return alwaysRestR, alwaysRestG, alwaysRestB end
        if restR and CL.GetSetting("classColorMenus") then return restR, restG, restB end
        -- Matches CL.ApplyButtonSkin's own resting color while pfUI is
        -- matched (SkinButton's CreateBackdrop call sets exactly this),
        -- so owning hover unconditionally doesn't fight the rest-state
        -- color pfUI itself set up.
        if CL.IsMatchPfui() and pfUI.api and pfUI.api.GetStringColor and pfUI_config then
            local ok, r, g, b = pcall(pfUI.api.GetStringColor, pfUI_config.appearance.border.color)
            if ok and r then return r, g, b end
        end
        return CL.FLAT_BORDER_R, CL.FLAT_BORDER_G, CL.FLAT_BORDER_B
    end
    local wasOver = false
    btn:SetScript("OnUpdate", function()
        if btn.pressedAt and (GetTime() - btn.pressedAt) > 0.15 then
            btn.pressedAt = nil
        end
        if not btn.pressedAt then
            local fr, fg, fb, fa = CL.GetButtonNormalFill()
            btn:SetBackdropColor(fr, fg, fb, fa)
        end
        local isOver = MouseIsOver(btn)
        if isOver ~= wasOver then
            if isOver then
                GameTooltip:SetOwner(btn, "ANCHOR_BOTTOM")
                GameTooltip:SetText(title, 1, 1, 1)
                if subtitle then
                    GameTooltip:AddLine(subtitle, 0.7, 0.7, 0.7)
                end
                GameTooltip:Show()
            else
                GameTooltip:Hide()
            end
            wasOver = isOver
        end
        if restR then
            if isOver then
                btn:SetBackdropBorderColor(1, 1, 1, 1)
            else
                local r, g, b = NormalBorderColor()
                btn:SetBackdropBorderColor(r, g, b, 1)
            end
        end
    end)
end

-- Posts this window's current mode/segment's top N (Options: Announce
-- Count) to the configured chat channel - one line per rank plus a
-- header, same shape GreedMeter's own announce button produces.
local function AnnounceTop(inst)
    local window = inst.frame
    local isThreat = (window.mode == "threat")

    local enc, units, list
    if isThreat then
        list = BuildThreatList(window.threatFilter)
    else
        enc = GetActiveEncounter(inst)
        units = enc and enc.units or {}
        list = BuildSortedList(units, window.mode)
    end
    if table.getn(list) == 0 then
        CL.Print("Nothing to announce - no data for the current mode" .. (isThreat and "" or "/segment") .. ".")
        return
    end

    local duration = 1
    if not isThreat then
        if window.segment == "overall" then
            duration = CL.Aggregator.GetOverallDuration()
        elseif enc then
            duration = (enc.duration and enc.duration > 0) and enc.duration or (GetTime() - enc.startTime)
        end
        if duration <= 0 then duration = 1 end
    end

    local segLabel = isThreat and "Live" or ((window.segment == "overall") and "Overall" or "Current Fight")
    local channel = CL.ResolveAnnounceChannel()
    local count = CL.GetSetting("announceCount") or 5
    if count > table.getn(list) then count = table.getn(list) end

    SendChatMessage("CombatLedger - " .. (MODE_TITLES[window.mode] or window.mode) .. " (" .. segLabel .. "):", channel)
    local i
    for i = 1, count do
        local entry = list[i]
        local line
        if isThreat then
            line = i .. ". " .. entry.name .. " - " .. FormatNumber(entry.total) .. " (" .. (entry.perc or 0) .. "%)" .. (entry.tank and " [Tank]" or "")
        elseif window.mode == "deaths" then
            line = i .. ". " .. entry.name .. " - " .. entry.total .. ((entry.total == 1) and " death" or " deaths")
        elseif COUNT_ONLY_MODES[window.mode] then
            line = i .. ". " .. entry.name .. " - " .. CountLabel(window.mode, entry.total)
        else
            line = i .. ". " .. entry.name .. " - " .. FormatNumber(entry.total) .. " (" .. FormatNumber(entry.total / duration) .. ")"
        end
        SendChatMessage(line, channel)
    end
end

-- `inst.defaultMode`/`defaultSegment` seed a fresh window (ignored once
-- a saved window state - see CL.GetWindowState - already has values).
local function CreateWindowFrame(inst)
    local id = inst.id
    local f = CreateFrame("Frame", "CombatLedgerMainWindow" .. (id == "main" and "" or id), UIParent)
    f:SetWidth(WINDOW_WIDTH)
    f:SetHeight(WINDOW_HEIGHT)
    f:SetPoint("CENTER", UIParent, "CENTER", 200, 0)
    f:SetBackdrop(CL.WINDOW_BACKDROP)
    local themeR, themeG, themeB, themeHex = CL.GetThemeColor()
    f:SetBackdropColor(0, 0, 0, CL.GetBackdropAlpha(0.8))
    f:SetBackdropBorderColor(themeR, themeG, themeB, 1)
    -- MEDIUM - HIGH still rendered above Blizzard's own Character/Bags/
    -- Quest-dialog panels on this client (confirmed via screenshot,
    -- covering CharacterFrame the same way FULLSCREEN_DIALOG did) -
    -- MEDIUM is what History/Breakdown/EncounterReport already used
    -- with no such complaint, so this matches those instead. The
    -- dropdown submenu (Core.lua's ShowDropdown) doesn't need a fixed
    -- TOOLTIP-always reservation either way - it computes its own
    -- strata as one tier above whatever anchor opened it, so it still
    -- reliably renders on top of this window regardless of which tier
    -- this window itself ends up at.
    f:SetFrameStrata("MEDIUM")
    -- Without this, whichever CombatLedger window got a structurally
    -- higher frame level at creation time permanently renders in front
    -- of every other "MEDIUM" window regardless of which was actually
    -- opened/clicked last - none of these windows called SetToplevel/
    -- Raise anywhere, so their relative order within the strata never
    -- changed after creation.
    f:SetToplevel(true)
    f:SetClampedToScreen(true) -- can't be dragged/pushed off-screen, unlike before
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function()
        if CL.GetSetting("lockWindow") then return end
        this:StartMoving()
    end)
    f:SetScript("OnDragStop", function()
        this:StopMovingOrSizing()
        CL.SaveLayout(id, this)
    end)
    f:Hide()

    CL.ApplyLayout(id, f, MIN_WINDOW_WIDTH, MIN_WINDOW_HEIGHT, MAX_WINDOW_WIDTH, MAX_WINDOW_HEIGHT)

    local savedWinState = CL.GetWindowState(id)
    f.mode = (savedWinState and savedWinState.mode) or inst.defaultMode or "damage"
    f.segment = (savedWinState and savedWinState.segment) or inst.defaultSegment or "current"
    -- Threat's own filter (which roster names to show - see
    -- ShowThreatFilterDropdown) instead of Current/Overall/History,
    -- since threat has neither. [name] = true means "included"; empty
    -- means "show everyone".
    f.threatFilter = (savedWinState and savedWinState.threatFilter) or {}

    -- Deliberately NOT registered in UISpecialFrames - this is a live
    -- meter meant to stay up throughout a session, not a dialog that
    -- should vanish on a stray Escape (easy to hit by accident while
    -- canceling a cast, closing another window, etc). Only /cl hide,
    -- /cl toggle, and (for extra windows) the close button hide it.
    --
    -- No separate title FontString anymore - modeBtn/segBtn below show
    -- the full mode name and segment directly (used to be short letter
    -- codes with a centered title stating the mode again), which reads
    -- just as clearly without a second element competing with the
    -- buttons for space at a narrow window width.

    -- Header row: Reset/Announce (left, compact single-letter - full
    -- names live in each button's own hover tooltip) ... Mode |
    -- Segment (right, click opens a dropdown - these two show the full
    -- word/name directly, see SetHeaderButtonText).
    local resetBtn = CreateHeaderButton(f, 18, "R")
    resetBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -6)
    resetBtn:SetScript("OnClick", function()
        StaticPopup_Show("COMBATLEDGER_RESET_OVERALL")
    end)
    SetButtonTooltip(resetBtn, "Reset", "Clear the Overall segment", themeR, themeG, themeB)
    CL.ApplyButtonSkin(resetBtn, themeR, themeG, themeB)
    f.resetBtn = resetBtn

    -- No header Options button anymore - redundant with the minimap
    -- icon's right-click (see UI_Options.lua's CreateMinimapButton),
    -- which already opens the exact same window; /cl options still
    -- works too if the minimap icon itself is hidden.
    local announceBtn = CreateHeaderButton(f, 18, "!")
    announceBtn:SetPoint("LEFT", resetBtn, "RIGHT", 4, 0)
    announceBtn:SetScript("OnClick", function()
        -- Confirm first - this button sits right next to Options/Reset
        -- in the header, easy to fat-finger, and firing it by accident
        -- spams whatever chat channel is configured.
        pendingAnnounceInst = inst
        StaticPopup_Show("COMBATLEDGER_ANNOUNCE", CL.GetSetting("announceCount") or 5)
    end)
    SetButtonTooltip(announceBtn, "Announce", "Post the top " .. (CL.GetSetting("announceCount") or 5) ..
        " to chat (channel/count set in Options)", themeR, themeG, themeB)
    CL.ApplyButtonSkin(announceBtn, themeR, themeG, themeB)
    f.announceBtn = announceBtn

    -- No per-window close button anymore - extra windows are created and
    -- closed exclusively from Options' Windows list now (CL.UI.
    -- CreateExtraWindow/CloseExtraWindow, wired up in UI_Options.lua),
    -- so every window's header is now IDENTICAL (main and extra both
    -- anchor segBtn straight off the window's own TOPRIGHT) instead of
    -- extra windows needing their own close-button-aware anchor math.
    local segBtn = CreateHeaderButton(f, 20, "")
    SetHeaderButtonText(segBtn, (f.mode == "threat") and "Filter" or SEGMENT_LABELS[f.segment], true)
    segBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)

    -- Threat has no Current/Overall/History (see Threat.lua) - this
    -- button becomes a name filter for it instead ("Filter"), same
    -- slot, different job. Called once at creation (a window can be
    -- created already in Threat mode, from a saved window state) and
    -- again on every mode switch.
    local function UpdateSegButtonForMode()
        if f.mode == "threat" then
            SetHeaderButtonText(segBtn, "Filter", true)
            SetButtonTooltip(segBtn, "Filter", "Choose which raid/party members show up in Threat mode", themeR, themeG, themeB)
        else
            SetHeaderButtonText(segBtn, SEGMENT_LABELS[f.segment], true)
            SetButtonTooltip(segBtn, "Segment", "Current Fight / Overall / a recent saved encounter", themeR, themeG, themeB)
        end
    end

    segBtn:SetScript("OnClick", function()
        -- Explicit, unconditional reset rather than relying on OnMouseUp
        -- (see CreateHeaderButton) to restore the press-darken color -
        -- opening a dropdown/menu from this handler was leaving it stuck
        -- in the darkened "pressed" state instead of releasing normally.
        segBtn:SetBackdropColor(0.12, 0.12, 0.14, 0.9)
        if f.mode == "threat" then
            ShowThreatFilterDropdown(inst)
            return
        end
        local options = {}
        local classColor = PlayerClassColorTable()
        table.insert(options, { label = "Overall", color = classColor, onClick = function()
            f.segment = "overall"
            SetHeaderButtonText(segBtn, SEGMENT_LABELS.overall, true)
            CL.SaveWindowState(id, f.mode, f.segment, f.threatFilter)
            RefreshInstance(inst)
        end })
        table.insert(options, { label = "Current", color = classColor, onClick = function()
            f.segment = "current"
            SetHeaderButtonText(segBtn, SEGMENT_LABELS.current, true)
            CL.SaveWindowState(id, f.mode, f.segment, f.threatFilter)
            RefreshInstance(inst)
        end })
        if CL.History then
            local hist = CL.History.GetHistory()
            local n = table.getn(hist)
            local limit = (n < 4) and n or 4 -- most recent 4 (+Current/Overall = 6 rows); full list + delete/clear lives in /cl history
            local i
            for i = 1, limit do
                local enc = hist[i]
                table.insert(options, { label = enc.label or "Encounter", onClick = function()
                    UI.ShowHistoryEncounterIn(inst, enc)
                end })
            end
        end
        CL.ShowDropdown(segBtn, options)
    end)
    UpdateSegButtonForMode()
    CL.ApplyButtonSkin(segBtn, themeR, themeG, themeB)
    f.segBtn = segBtn

    local modeBtn = CreateHeaderButton(f, 20, "")
    SetHeaderButtonText(modeBtn, MODE_TITLES[f.mode] or f.mode, false)
    modeBtn:SetPoint("RIGHT", segBtn, "LEFT", -4, 0)
    modeBtn:SetScript("OnClick", function()
        -- Same explicit reset as segBtn above - see that comment.
        modeBtn:SetBackdropColor(0.12, 0.12, 0.14, 0.9)
        local options = {}
        local i
        for i = 1, table.getn(MODE_ORDER) do
            local key = MODE_ORDER[i]
            table.insert(options, { label = MODE_TITLES[key] or key, onClick = function()
                f.mode = key
                SetHeaderButtonText(modeBtn, MODE_TITLES[key] or key, false)
                UpdateSegButtonForMode()
                CL.SaveWindowState(id, f.mode, f.segment, f.threatFilter)
                RefreshInstance(inst)
            end })
        end
        CL.ShowDropdown(modeBtn, options)
    end)
    SetButtonTooltip(modeBtn, "Mode", "Damage Done / Healing Done / Damage Taken / Dispels / Debuffs / Interrupts / Deaths / Threat", themeR, themeG, themeB)
    CL.ApplyButtonSkin(modeBtn, themeR, themeG, themeB)
    f.modeBtn = modeBtn

    -- A real ScrollFrame (not a whole-row index shift like the History
    -- window) so a bar that only partially fits the remaining space
    -- renders cut off right at the edge instead of being hidden
    -- entirely or leaving blank space below the last whole one - scroll
    -- wheel moves through the rest via SetVerticalScroll.
    local barScroll = CreateFrame("ScrollFrame", nil, f)
    barScroll:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -HEADER_HEIGHT)
    barScroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, FooterGap())
    f.barScroll = barScroll

    -- SetScrollChild manages the child's own position internally - it
    -- must NOT be anchored with SetPoint beforehand (that left it
    -- effectively unpositioned/invisible, taking every bar with it).
    -- Width has to be tracked explicitly instead (kept in sync on
    -- resize, see the grip's OnUpdate and RestyleAll above) since a
    -- ScrollFrame's own GetWidth() is anchor-derived and not reliably
    -- readable right after a size change on this client.
    local barParent = CreateFrame("Frame", nil, barScroll)
    barParent:SetWidth(f:GetWidth() - 12)
    barParent:SetHeight(MAX_BARS * (CL.GetBarHeight(BAR_HEIGHT) + BAR_GAP))
    f.barParent = barParent
    barScroll:SetScrollChild(barParent)

    barScroll:EnableMouseWheel(true)
    barScroll:SetScript("OnMouseWheel", function()
        local delta = arg1
        if not delta then return end
        local scrollStep = CL.GetBarHeight(BAR_HEIGHT) + BAR_GAP
        local cur = barScroll:GetVerticalScroll()
        local maxScroll = GetMaxBarScroll(f)
        local new = cur - delta * scrollStep
        if new < 0 then new = 0 end
        if new > maxScroll then new = maxScroll end
        barScroll:SetVerticalScroll(new)
    end)

    local i
    for i = 1, MAX_BARS do
        inst.bars[i] = CreateBar(inst, barParent, i)
    end

    -- Bottom-right resize grip, same tinted-square approach as
    -- LootLedger's (Blizzard's chat-frame resize texture doesn't render
    -- on this client).
    local grip = CreateFrame("Button", nil, f)
    grip:SetWidth(16)
    grip:SetHeight(16)
    grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
    grip:SetFrameLevel(f:GetFrameLevel() + 10)
    grip:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
    grip:SetBackdropColor(themeR, themeG, themeB, 0.4)
    grip:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_LEFT")
        GameTooltip:SetText("Drag to resize")
        GameTooltip:Show()
    end)
    grip:SetScript("OnLeave", function() GameTooltip:Hide() end)
    grip:SetScript("OnMouseDown", function()
        if CL.GetSetting("lockWindow") then return end
        this.sizing = true
        this.startX, this.startY = GetCursorPosition()
        this.startW, this.startH = f:GetWidth(), f:GetHeight()
        this.scale = f:GetEffectiveScale()
    end)
    grip:SetScript("OnMouseUp", function()
        this.sizing = nil
        CL.SaveLayout(id, f)
    end)
    grip:SetScript("OnUpdate", function()
        if not this.sizing then return end
        local x, y = GetCursorPosition()
        local scale = this.scale or 1
        local newW = this.startW + (x - this.startX) / scale
        local newH = this.startH - (y - this.startY) / scale
        if newW < MIN_WINDOW_WIDTH then newW = MIN_WINDOW_WIDTH end
        if newW > MAX_WINDOW_WIDTH then newW = MAX_WINDOW_WIDTH end
        if newH < MIN_WINDOW_HEIGHT then newH = MIN_WINDOW_HEIGHT end
        if newH > MAX_WINDOW_HEIGHT then newH = MAX_WINDOW_HEIGHT end
        f:SetWidth(newW)
        f:SetHeight(newH)
        barParent:SetWidth(newW - 12)
        -- Mode/Segment shrink live as the window narrows (see
        -- SetHeaderButtonText) instead of only picking up the new width
        -- on the next label change.
        ReflowHeaderButton(f.segBtn)
        ReflowHeaderButton(f.modeBtn)
    end)
    if CL.GetSetting("lockWindow") then grip:Hide() end
    f.resizeGrip = grip

    -- Only pfUI-skins the window's own chrome while "Match pfUI" is on -
    -- CreateBackdrop applies pfUI's background/border unconditionally
    -- whenever pfUI is loaded at all, which would override the manual
    -- opacity/texture Options even with Match pfUI unchecked.
    CL.ApplyWindowSkin(f, themeR, themeG, themeB, 0.8)

    inst.frame = f
    return f
end

RefreshInstance = function(inst)
    local window = inst.frame
    if not window or not window:IsShown() then return end

    local isThreat = (window.mode == "threat")
    local enc, list, threatMarker
    local duration = 1

    if isThreat then
        list, threatMarker = BuildThreatList(window.threatFilter)
    else
        enc = GetActiveEncounter(inst)
        local units = enc and enc.units or {}
        list = BuildSortedList(units, window.mode)

        if window.segment == "overall" then
            -- Active-combat time only, frozen between fights - see
            -- Aggregator's GetOverallDuration.
            duration = CL.Aggregator.GetOverallDuration()
        elseif enc then
            if enc.duration and enc.duration > 0 then
                duration = enc.duration
            else
                duration = GetTime() - enc.startTime
            end
        end
        if duration <= 0 then duration = 1 end
    end

    local maxVal = 1
    if list[1] and list[1].total > 0 then
        maxVal = list[1].total
    end

    -- Pinned to the very top regardless of sort order - it's a
    -- reference line, not a real threat total, so it never competes for
    -- the #1 spot on its own (tiny) value.
    if threatMarker then
        table.insert(list, 1, threatMarker)
    end

    local shown = 0
    local rank = 0
    local i
    for i = 1, MAX_BARS do
        local bar = inst.bars[i]
        local entry = list[i]
        if entry then
            shown = shown + 1
            local pct = entry.total / maxVal
            if pct > 1 then pct = 1 end
            if entry.isAgroMarker then pct = 1 end -- always full-width, a reference line not a real total
            bar.targetPct = pct
            -- Smoothing looks nice mid-fight (bars glide instead of
            -- jumping every refresh tick), but that same glide is what
            -- made the STOP itself feel laggy - the encounter's data
            -- finalizes instantly (see Aggregator.lua's FinishEncounter/
            -- EndEncounter), yet the bar could still take up to ~1s to
            -- visually catch up to its true final length. Snap straight
            -- to the target instead of animating whenever there's no
            -- live encounter actually running (i.e. Current Fight is
            -- showing the frozen last-finished result, not a fight in
            -- progress) - the glide only applies while something's
            -- actually still live to glide toward.
            local shouldSnap = not CL.IsSmoothBars()
                or (not isThreat and window.segment == "current" and not CL.Aggregator.GetCurrent())
            if shouldSnap then
                bar:SetValue(pct)
            end
            if entry.isAgroMarker then
                bar:SetStatusBarColor(0.75, 0.1, 0.1, 0.9)
                bar.nameText:SetText(entry.name)
                bar.valueText:SetText("+" .. FormatNumber(entry.total))
            elseif isThreat then
                rank = rank + 1
                local r, g, b = ClassColor(entry.classToken)
                bar:SetStatusBarColor(r, g, b, 0.9)
                bar.nameText:SetText(rank .. ". " .. (entry.tank and "|cffFFD100[T]|r " or "") .. entry.name)
                bar.valueText:SetText(FormatNumber(entry.total) .. "  (" .. (entry.perc or 0) .. "%)")
            else
                rank = rank + 1
                local r, g, b = ClassColor(entry.classToken)
                bar:SetStatusBarColor(r, g, b, 0.9)
                bar.nameText:SetText(rank .. ". " .. entry.name)
                if window.mode == "deaths" then
                    bar.valueText:SetText(entry.total .. ((entry.total == 1) and " death" or " deaths"))
                elseif COUNT_ONLY_MODES[window.mode] then
                    bar.valueText:SetText(CountLabel(window.mode, entry.total))
                else
                    local rate = entry.total / duration
                    bar.valueText:SetText(FormatNumber(entry.total) .. "  (" .. FormatNumber(rate) .. ")")
                end
            end

            -- Bar border - two independent Options settings (each with
            -- its own user-pickable color) sharing one overlay frame
            -- (see CreateBar). "Highlight my bar" (self only) wins
            -- whenever it applies, since the whole point is picking your
            -- own row out at a glance - a same-colored general border
            -- around every bar would defeat that. Otherwise "Show bar
            -- border" applies its own color to every row. Neither ever
            -- applies to the agro marker - it's a reference line, not a
            -- real player row.
            if entry.isAgroMarker then
                bar.borderFrame:SetBackdropBorderColor(1, 1, 1, 0)
            elseif CL.GetSetting("highlightSelf") and entry.name == UnitName("player") then
                local sc = CL.GetSetting("highlightSelfColor")
                bar.borderFrame:SetBackdropBorderColor(sc[1], sc[2], sc[3], 1)
            elseif CL.GetSetting("barBorderEnabled") then
                local bc = CL.GetSetting("barBorderColor")
                bar.borderFrame:SetBackdropBorderColor(bc[1], bc[2], bc[3], 1)
            else
                bar.borderFrame:SetBackdropBorderColor(1, 1, 1, 0)
            end

            -- Class icon - opt-in (Options: "Show class icon"), and
            -- only for entries that resolved a real class (not the
            -- aggro-marker reference row, and not mobs/unresolved
            -- units, which have no classToken at all). SetPoint on the
            -- same anchor point ("LEFT") replaces the previous one, so
            -- this doesn't need a ClearAllPoints first.
            if not entry.isAgroMarker and CL.GetSetting("showClassIcon") and entry.classToken and CL.CLASS_ICON_TCOORDS[entry.classToken] then
                local coords = CL.CLASS_ICON_TCOORDS[entry.classToken]
                bar.classIcon:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
                bar.classIcon:Show()
                bar.nameText:SetPoint("LEFT", bar.classIcon, "RIGHT", 3, 0)
            else
                bar.classIcon:Hide()
                bar.nameText:SetPoint("LEFT", bar, "LEFT", 4, 0)
            end

            bar.guid = entry.guid
            bar:Show()
        else
            bar.guid = nil
            bar:Hide()
        end
    end

    -- Scroll child's height tracks how many entries are actually shown,
    -- not the full MAX_BARS pool - otherwise the scroll range extends
    -- into empty unused pool space past the real last bar. Only touched
    -- when the count actually changes, not every 0.2s refresh - this
    -- client doesn't reliably keep a ScrollFrame's scroll range usable
    -- under constant SetHeight churn on its scroll child (same class of
    -- geometry-staleness issue documented elsewhere in this addon).
    if shown ~= inst.lastShownCount then
        inst.lastShownCount = shown
        window.barParent:SetHeight(math.max(shown, 1) * (CL.GetBarHeight(BAR_HEIGHT) + BAR_GAP))
    end

    -- Re-clamp scroll position in case the list got shorter (mode/
    -- segment switch, a unit dropping off) since the last scroll -
    -- SetVerticalScroll doesn't do this on its own if the scroll child
    -- shrinks out from under an existing offset.
    local maxScroll = GetMaxBarScroll(window)
    if window.barScroll:GetVerticalScroll() > maxScroll then
        window.barScroll:SetVerticalScroll(maxScroll)
    end
end

-- Threat mode's stand-in for the segment button (see UpdateSegButtonFor
-- Mode in CreateWindowFrame) - a toggle list of every known raid/party
-- name instead of Current/Overall/History. Reuses the same shared
-- ShowDropdown/dropdownFrame as everything else; each row's onClick
-- toggles that name and re-opens itself immediately after ShowDropdown
-- closes it, which reads as a dropdown that "stays open" for picking
-- several names in one go without actually needing a second dropdown
-- implementation that behaves differently from every other menu here.
ShowThreatFilterDropdown = function(inst)
    local f = inst.frame
    local names = (CL.Threat and CL.Threat.GetRosterNames and CL.Threat.GetRosterNames()) or {}
    local options = {}

    if table.getn(names) == 0 then
        table.insert(options, { label = "No group members found", onClick = function() end })
    else
        local i
        for i = 1, table.getn(names) do
            local name = names[i]
            local included = f.threatFilter[name]
            table.insert(options, {
                label = (included and "|cff33ff33[x]|r " or "|cff888888[ ]|r ") .. name,
                onClick = function()
                    if included then
                        f.threatFilter[name] = nil
                    else
                        f.threatFilter[name] = true
                    end
                    CL.SaveWindowState(inst.id, f.mode, f.segment, f.threatFilter)
                    RefreshInstance(inst)
                    ShowThreatFilterDropdown(inst)
                end,
            })
        end
        table.insert(options, { label = "|cffff5555Clear Filter (show everyone)|r", onClick = function()
            f.threatFilter = {}
            CL.SaveWindowState(inst.id, f.mode, f.segment, f.threatFilter)
            RefreshInstance(inst)
        end })
    end

    CL.ShowDropdown(f.segBtn, options)
end

local function NewInstance(id, opts)
    opts = opts or {}
    local inst = {
        id = id,
        frame = nil,
        bars = {},
        lastShownCount = -1,
        defaultMode = opts.defaultMode,
        defaultSegment = opts.defaultSegment,
    }
    instances[id] = inst
    table.insert(instanceOrder, id)
    return inst
end

local function ShowInstance(inst)
    if not inst.frame then CreateWindowFrame(inst) end
    inst.frame:Show()
    RefreshInstance(inst)
end

-- Opens a saved encounter (from History.lua) in the same bar-list/
-- breakdown-click UI as the live meter, rather than a chat dump - reuses
-- everything, just points GetActiveEncounter at a static snapshot
-- instead of Current/Overall.
function UI.ShowHistoryEncounterIn(inst, encounter)
    if not encounter then return end
    if not inst.frame then CreateWindowFrame(inst) end
    inst.frame.segment = "history"
    inst.frame.historyEncounter = encounter
    if inst.frame.segBtn then
        SetHeaderButtonText(inst.frame.segBtn, encounter.label or SEGMENT_LABELS.history, true)
    end
    CL.SaveWindowState(inst.id, inst.frame.mode, inst.frame.segment, inst.frame.threatFilter)
    inst.frame:Show()
    RefreshInstance(inst)
end

--------------------------------------------------------------------------
-- Extra window management (Options' "New Window" list)
--------------------------------------------------------------------------

local nextExtraNum = 2

-- id -> label shown in Options' window list
function UI.GetWindowList()
    local list = {}
    local i
    for i = 1, table.getn(instanceOrder) do
        local id = instanceOrder[i]
        local inst = instances[id]
        if inst then
            local label = (inst.frame and MODE_TITLES[inst.frame.mode]) or (inst.defaultMode and MODE_TITLES[inst.defaultMode]) or "Window"
            table.insert(list, { id = id, label = label, closable = (id ~= "main") })
        end
    end
    return list
end

function UI.CreateExtraWindow()
    local id = "window" .. nextExtraNum
    while instances[id] do
        nextExtraNum = nextExtraNum + 1
        id = "window" .. nextExtraNum
    end
    nextExtraNum = nextExtraNum + 1
    local inst = NewInstance(id)
    CL.SaveWindowState(id, inst.defaultMode or "damage", inst.defaultSegment or "current")
    ShowInstance(inst)
    return id
end

function UI.CloseExtraWindow(id)
    if id == "main" then return end
    local inst = instances[id]
    if not inst then return end
    if inst.frame then inst.frame:Hide() end
    instances[id] = nil
    local i
    for i = 1, table.getn(instanceOrder) do
        if instanceOrder[i] == id then
            table.remove(instanceOrder, i)
            break
        end
    end
    CL.ForgetWindowState(id)
end

local function IsGrouped()
    return ((GetNumRaidMembers and GetNumRaidMembers()) or 0) > 0
        or ((GetNumPartyMembers and GetNumPartyMembers()) or 0) > 0
end

-- Whether id's own Auto-hide/Grouped-only rules currently forbid
-- showing it, given LIVE combat/group state right now. Shared by
-- login/reload restore (below) and by Options' Hide/Grouped checkboxes
-- (UI_Options.lua) - unchecking one of those two shouldn't force the
-- window into view if the OTHER rule still says it shouldn't be up
-- (e.g. unchecking Auto-hide while Grouped-only is on and you're
-- solo used to show the window anyway, which was wrong).
function UI.IsSuppressedNow(id)
    local onlyGrouped = CL.GetWindowOption(id, "onlyShowGrouped", false)
    if onlyGrouped and not IsGrouped() then return true end
    local autoHide = CL.GetWindowOption(id, "autoHideOutOfCombat", false)
    if autoHide and not UnitAffectingCombat("player") then return true end
    return false
end

-- Restores every window (main + every remembered extra) at login/
-- reload, honoring each window's own Auto-hide/Grouped-only rules
-- instead of unconditionally showing everything and letting the first
-- combat/group event sort it out later - a window set to only ever be
-- up while grouped-and-fighting shouldn't flash on-screen at login just
-- because nothing has "happened" yet to hide it again. Auto-show plays
-- no part here on purpose - it's a "combat just started" trigger, not a
-- statement about the window's resting state.
function UI.RestoreAllWindows()
    local function RestoreOne(id, inst)
        if UI.IsSuppressedNow(id) then
            CreateWindowFrame(inst)
            inst.frame:Hide()
        else
            ShowInstance(inst)
        end
    end

    RestoreOne("main", instances["main"])

    local ids = CL.GetExtraWindowIds()
    local i
    for i = 1, table.getn(ids) do
        local id = ids[i]
        if id ~= "main" and not instances[id] then
            RestoreOne(id, NewInstance(id))
        end
    end
end

--------------------------------------------------------------------------
-- Main instance - the public CL.UI surface everything else (Events.lua,
-- the minimap button, /cl commands, UI_BreakdownWindow's fallback) uses.
--------------------------------------------------------------------------

local mainInst = NewInstance("main")

-- Show/Hide/Toggle apply to EVERY open window now, not just main - the
-- minimap icon's left-click, /cl toggle, and auto-show-in-combat/auto-
-- hide-out-of-combat are all addon-wide behaviors, not main-window-only
-- ones, and with extra windows no longer having their own close button
-- (see CreateWindowFrame - creation/closing is Options-only now), main
-- was the only thing responding to any of them, leaving secondary
-- meters stuck showing (or hidden) regardless. Toggle's own on/off
-- decision still keys off mainInst specifically, treating it as the
-- reference point for "are we currently shown."
--
-- Show skips any window UI.IsSuppressedNow says shouldn't be up right
-- now (Grouped-only and you're solo, or Auto-hide and you're out of
-- combat) - a manual toggle used to force EVERY window on regardless,
-- which directly defeated the point of those settings (a Threat meter
-- set to grouped-only would still pop up solo the moment you clicked
-- the minimap icon).
function UI.Show()
    local id, inst
    for id, inst in pairs(instances) do
        if not UI.IsSuppressedNow(id) then
            ShowInstance(inst)
        end
    end
end

function UI.Hide()
    local id, inst
    for id, inst in pairs(instances) do
        if inst.frame then inst.frame:Hide() end
    end
end

function UI.Toggle()
    if mainInst.frame and mainInst.frame:IsShown() then
        UI.Hide()
    else
        UI.Show()
    end
end

-- One-time copy of Main's current size/position onto another window -
-- not a persistent link, so either window can still be freely resized/
-- moved afterward without dragging the other one along. Reuses
-- CL.SaveLayout (normally called from a window's own resize-grip/drag
-- handlers on itself) by pointing it at mainInst's frame but saving
-- under the TARGET window's id, then re-applies that saved layout to
-- the target's actual frame if it's currently open.
function UI.MirrorMainLayout(id)
    if id == "main" or not mainInst.frame then return end
    CL.SaveLayout(id, mainInst.frame)
    local inst = instances[id]
    if inst and inst.frame then
        CL.ApplyLayout(id, inst.frame, MIN_WINDOW_WIDTH, MIN_WINDOW_HEIGHT, MAX_WINDOW_WIDTH, MAX_WINDOW_HEIGHT)
    end
end

-- Shows one specific window by id, creating its frame if needed (same
-- lazy-create as ShowInstance) - used by Options' per-window Hide/
-- Grouped checkboxes to reveal a window immediately when a restriction
-- is unchecked, without having to wait for (or fake) a combat/group
-- transition event.
function UI.ShowWindowById(id)
    local inst = instances[id]
    if inst then ShowInstance(inst) end
end

-- Called on PLAYER_REGEN_DISABLED (combat start) - shows every window
-- with its own "Auto-show on combat start" option on. A window that
-- also has "Only show while grouped" on is skipped here if you're not
-- currently grouped (e.g. a Threat meter that should only ever appear
-- for a real pull, not solo combat).
function UI.ApplyAutoShow()
    local id, inst
    for id, inst in pairs(instances) do
        if CL.GetWindowOption(id, "autoShowInCombat", true) then
            if not CL.GetWindowOption(id, "onlyShowGrouped", false) or IsGrouped() then
                ShowInstance(inst)
            end
        end
    end
end

-- Called (only while out of combat - see Events.lua's own guard) to
-- hide every window with its own "Auto-hide out of combat" option on.
function UI.ApplyAutoHide()
    local id, inst
    for id, inst in pairs(instances) do
        if CL.GetWindowOption(id, "autoHideOutOfCombat", false) and inst.frame then
            inst.frame:Hide()
        end
    end
end

-- Called on any group roster change - a window with "Only show while
-- grouped" hides immediately the moment you're no longer grouped, and
-- shows immediately the moment you're grouped again, PROVIDED nothing
-- else currently required is still missing - UI.IsSuppressedNow already
-- encodes that combined rule (Grouped-only needs grouped, Auto-hide
-- needs combat, independently of each other), so joining a group alone
-- is enough to reveal a Grouped-only window that doesn't also have
-- Auto-hide on, without waiting for combat to start - this used to
-- hard-require being in combat unconditionally, which was wrong
-- whenever Auto-hide wasn't checked (i.e. combat was never actually a
-- requirement for that window in the first place).
function UI.ReconcileGroupVisibility()
    local id, inst
    for id, inst in pairs(instances) do
        if CL.GetWindowOption(id, "onlyShowGrouped", false) then
            if not IsGrouped() then
                if inst.frame then inst.frame:Hide() end
            elseif CL.GetWindowOption(id, "autoShowInCombat", true) and not UI.IsSuppressedNow(id) then
                ShowInstance(inst)
            end
        end
    end
end

function UI.Refresh()
    RefreshInstance(mainInst)
end

-- Every open window (main + any "+ New Window" extras) at once - used
-- where a change isn't scoped to just the main window, e.g. clearing
-- Overall from the join-party prompt below.
function UI.RefreshAllInstances()
    for _, inst in pairs(instances) do
        RefreshInstance(inst)
    end
end

-- Called by Threat.lua the moment a fresh threat packet arrives, so
-- threat bars update immediately instead of waiting for the next
-- throttled tick - every other mode's data only changes on our own
-- event pipeline (already inside the same throttled refresh loop), but
-- threat is a live server push on its own ~0.5s cadence.
function UI.RefreshMode(mode)
    local id, inst
    for id, inst in pairs(instances) do
        if inst.frame and inst.frame.mode == mode then
            RefreshInstance(inst)
        end
    end
end

-- Threat.lua polls the server on its own timer only while this is true,
-- rather than unconditionally every 0.5s regardless of whether anyone's
-- actually looking at Threat mode - same reasoning TWThreat's own
-- update loop uses (it only queries while at least one of its display
-- features is actually enabled).
function UI.IsModeVisible(mode)
    local id, inst
    for id, inst in pairs(instances) do
        if inst.frame and inst.frame.mode == mode and inst.frame:IsShown() then
            return true
        end
    end
    return false
end

function UI.GetActiveModeSegment()
    if not mainInst.frame then return "damage", "current" end
    return mainInst.frame.mode, mainInst.frame.segment
end

function UI.GetActiveEncounter()
    return GetActiveEncounter(mainInst)
end

function UI.ShowHistoryEncounter(encounter)
    UI.ShowHistoryEncounterIn(mainInst, encounter)
end

-- Throttled refresh loop for every open window - only does work while a
-- window is actually shown (RefreshInstance bails immediately
-- otherwise). Bar-value smoothing runs every frame, separately from the
-- throttle, so bars glide toward their new value instead of jumping -
-- like Details' animated bars - rather than only updating in
-- REFRESH_INTERVAL-sized steps.
local driver = CreateFrame("Frame")
local accum = 0
driver:SetScript("OnUpdate", function()
    local id, inst
    for id, inst in pairs(instances) do
        local window = inst.frame
        if window and window:IsShown() and CL.IsSmoothBars() then
            local speed = CL.GetBarSpeed() -- 1 (slow) - 10 (near-instant)
            local rate = speed * 1.6 * arg1
            if rate > 1 then rate = 1 end
            local i
            for i = 1, table.getn(inst.bars) do
                local bar = inst.bars[i]
                if bar:IsShown() and bar.targetPct then
                    local cur = bar:GetValue()
                    local target = bar.targetPct
                    if math.abs(target - cur) < 0.002 then
                        bar:SetValue(target)
                    else
                        bar:SetValue(cur + (target - cur) * rate)
                    end
                end
            end
        end
    end

    accum = accum + arg1
    if accum < REFRESH_INTERVAL then return end
    accum = 0
    for id, inst in pairs(instances) do
        RefreshInstance(inst)
    end
end)

StaticPopupDialogs["COMBATLEDGER_RESET_OVERALL"] = {
    text = "Clear the Overall segment? Current Fight and saved History aren't affected.",
    button1 = "Yes",
    button2 = "No",
    OnAccept = function()
        CL.Aggregator.ResetOverall()
        for _, inst in pairs(instances) do
            RefreshInstance(inst)
        end
    end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
    exclusive = 1,
}

StaticPopupDialogs["COMBATLEDGER_CLEAR_ON_JOIN"] = {
    text = "Clear the Overall segment? You just joined a group.",
    button1 = "Yes",
    button2 = "No",
    OnAccept = function()
        CL.Aggregator.ResetOverall()
        UI.RefreshAllInstances()
        CL.Print("Overall cleared.")
    end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
    exclusive = 1,
}

StaticPopupDialogs["COMBATLEDGER_ANNOUNCE"] = {
    text = "Post the top %d to chat?", -- %d filled in from StaticPopup_Show's text_arg1 (the announce count)
    button1 = "Yes",
    button2 = "No",
    OnAccept = function()
        if pendingAnnounceInst then
            AnnounceTop(pendingAnnounceInst)
            pendingAnnounceInst = nil
        end
    end,
    OnCancel = function()
        pendingAnnounceInst = nil
    end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
    exclusive = 1,
}

-- NOT called here at file-load time - this client restores the real
-- CombatLedgerDB from disk AFTER all files finish executing, so
-- CreateWindowFrame's CL.ApplyLayout would always read an empty
-- placeholder and silently never restore the saved size/position (every
-- reload, not just occasionally). Events.lua's first PLAYER_ENTERING_WORLD
-- calls UI.RestoreAllWindows() instead, once the real saved data is
-- actually there.
