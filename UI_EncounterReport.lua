--[[
    UI_EncounterReport - a real per-encounter summary: shape-of-the-fight
    graph (Aggregator's bucketed series) plus a leaderboard, for one
    saved (or the live) encounter. Opened from a History row's "Report"
    button, or /cl report for whatever's currently showing as Current
    Fight.

    Deliberately not a full event-by-event log viewer - see Aggregator's
    series comment for why that tradeoff was made. This is the first
    real consumer of series data; a future scrubbable timeline (click a
    graph point, see exactly what landed there) would need a separate,
    live-only raw event buffer layered on top of this, the same way
    DeathRecap's rolling buffer already works.
]]

local CL = CombatLedger
local RC = {}
CL.UIEncounterReport = RC

local HEADER_HEIGHT = 40
local TOGGLE_HEIGHT = 20
local GRAPH_HEIGHT = 90
local LEADER_GAP_ABOVE = 6
local BAR_HEIGHT = 16
local BAR_GAP = 2
local FOOTER_GAP = 12
local MAX_LEADER_BARS = 10
local GRAPH_BARS = 40

local WINDOW_WIDTH, WINDOW_HEIGHT = 400, 400
local MIN_WINDOW_WIDTH, MIN_WINDOW_HEIGHT = 300, 280
local MAX_WINDOW_WIDTH, MAX_WINDOW_HEIGHT = 700, 700

local METRIC_UNIT_FIELD = { damage = "damageDone", healing = "healingDone", taken = "damageTaken" }
local METRIC_LABELS = { damage = "Damage", healing = "Healing", taken = "Taken", abilities = "Abilities" }
local METRIC_ORDER = { "damage", "healing", "taken", "abilities" }
local METRIC_COLOR = {
    damage = { 0.95, 0.55, 0.15 },
    healing = { 0.25, 0.85, 0.35 },
    taken = { 0.85, 0.2, 0.2 },
}

-- "Abilities" mode plots raid-wide damage-by-ability over time (see
-- Aggregator's abilitySeries - boss fights only) as a multi-line graph
-- instead of the single-color bar chart the other 3 metrics use. Capped
-- to the top N by total damage - a real boss rotation still has way more
-- distinct abilities than are readable as simultaneous lines on a ~400px
-- graph, so anything past this rank is just left off rather than fighting
-- for space. Same 6-color wheel doubles as the legend's own swatch order.
local MAX_GRAPH_ABILITIES = 6
local ABILITY_LINE_COLORS = {
    { 0.95, 0.55, 0.15 }, { 0.35, 0.65, 0.95 }, { 0.85, 0.35, 0.85 },
    { 0.95, 0.85, 0.25 }, { 0.35, 0.85, 0.55 }, { 0.85, 0.25, 0.25 },
}
local LINE_THICKNESS = 2

local window = nil
local toggleBtns = {}
local graphBars = {}
local leaderBars = {}
local graphHoverCols = {}
-- Per-ability "step line" segments - two textures per gap between
-- adjacent graph columns (a horizontal run at the earlier point's height,
-- then a vertical riser up/down to the next point's height), no diagonal
-- texture rotation needed since vanilla's Texture API doesn't have any.
-- Sized MAX_GRAPH_ABILITIES x (GRAPH_BARS - 1) pairs, created once and
-- just shown/hidden/repositioned on every refresh like every other pool
-- in this file.
local abilityLineH = {}
local abilityLineV = {}

local function FormatNumber(n)
    return CL.FormatNumber(n)
end

local function FormatClock(seconds)
    seconds = math.floor((seconds or 0) + 0.5)
    if seconds < 0 then seconds = 0 end
    local m = math.floor(seconds / 60)
    local s = seconds - (m * 60)
    return string.format("%d:%02d", m, s)
end

local function ClassColorHex(classToken)
    if classToken and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken] then
        local c = RAID_CLASS_COLORS[classToken]
        return string.format("%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
    end
    return "ffffff"
end

local function ClassColorRGB(classToken)
    if classToken and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken] then
        local c = RAID_CLASS_COLORS[classToken]
        return c.r, c.g, c.b
    end
    return 0.7, 0.7, 0.7
end

-- Downsamples encounter.series (fixed 2s buckets, may run long past
-- GRAPH_BARS worth of them) into exactly GRAPH_BARS points, each the
-- average per-second rate over its merged window - averaging by actual
-- elapsed seconds (not just bucket count) keeps a shorter trailing
-- group from reading as artificially taller/shorter than a full one.
-- 3rd return value is how many real seconds of the fight each downsampled
-- column covers - callers use it to label the X axis and to compute each
-- column's actual start/end time for tooltips, since a column's width in
-- raw buckets (perGroup) alone doesn't say that in seconds.
local function BuildGraphPoints(encounter, metric)
    local series = (encounter and encounter.series) or {}
    local total = table.getn(series)
    local points = {}
    local bucketSeconds = (CL.Aggregator and CL.Aggregator.SERIES_BUCKET_SECONDS) or 2
    if total < 1 then return points, 0, bucketSeconds end

    local perGroup = math.ceil(total / GRAPH_BARS)
    if perGroup < 1 then perGroup = 1 end

    local i = 1
    local maxRate = 0
    while i <= total do
        local groupEnd = i + perGroup - 1
        if groupEnd > total then groupEnd = total end
        local sum = 0
        local j
        for j = i, groupEnd do
            local b = series[j]
            if b then sum = sum + (b[metric] or 0) end
        end
        local seconds = (groupEnd - i + 1) * bucketSeconds
        local rate = (seconds > 0) and (sum / seconds) or 0
        table.insert(points, rate)
        if rate > maxRate then maxRate = rate end
        i = i + perGroup
    end

    return points, maxRate, perGroup * bucketSeconds
end

-- Same downsample-to-GRAPH_BARS idea as BuildGraphPoints, but per-ability
-- instead of per-metric, and reading abilitySeries/ABILITY_BUCKET_SECONDS
-- (1s buckets) instead of series/SERIES_BUCKET_SECONDS (2s). Returns the
-- top MAX_GRAPH_ABILITIES entries (by whole-fight total), each with its
-- own `.points` array and `.color`/`.name`/`.total`, plus the shared
-- maxRate every entry's points were scaled against (so lines stay
-- comparable to each other on one shared Y axis).
local function BuildAbilityGraphSeries(encounter)
    local series = (encounter and encounter.abilitySeries) or {}
    local totals = (encounter and encounter.abilityTotals) or {}
    local names = (encounter and encounter.abilityNames) or {}
    local totalBuckets = table.getn(series)
    local bucketSeconds = (CL.Aggregator and CL.Aggregator.ABILITY_BUCKET_SECONDS) or 1
    if totalBuckets < 1 then return {}, 0, bucketSeconds end

    local ranked = {}
    local key, total
    for key, total in pairs(totals) do
        table.insert(ranked, { key = key, total = total, name = names[key] or tostring(key), points = {} })
    end
    table.sort(ranked, function(a, b) return a.total > b.total end)

    local top = {}
    local i
    for i = 1, MAX_GRAPH_ABILITIES do
        if ranked[i] then
            ranked[i].color = ABILITY_LINE_COLORS[i]
            table.insert(top, ranked[i])
        end
    end
    if table.getn(top) == 0 then return top, 0, bucketSeconds end

    local perGroup = math.ceil(totalBuckets / GRAPH_BARS)
    if perGroup < 1 then perGroup = 1 end

    local maxRate = 0
    local groupStart = 1
    while groupStart <= totalBuckets do
        local groupEnd = groupStart + perGroup - 1
        if groupEnd > totalBuckets then groupEnd = totalBuckets end
        local seconds = (groupEnd - groupStart + 1) * bucketSeconds
        local a
        for a = 1, table.getn(top) do
            local sum = 0
            local j
            for j = groupStart, groupEnd do
                local bucket = series[j]
                sum = sum + ((bucket and bucket[top[a].key]) or 0)
            end
            local rate = (seconds > 0) and (sum / seconds) or 0
            table.insert(top[a].points, rate)
            if rate > maxRate then maxRate = rate end
        end
        groupStart = groupStart + perGroup
    end

    return top, maxRate, perGroup * bucketSeconds
end

local function CreateGraphBar(parent)
    local tex = parent:CreateTexture(nil, "ARTWORK")
    tex:SetTexture(CL.GetBarTexture())
    tex:Hide()
    return tex
end

local function CreateLeaderBar(parent, index)
    local height = CL.GetBarHeight(BAR_HEIGHT)
    local bar = CreateFrame("Button", nil, parent)
    bar:SetHeight(height)
    bar:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -((index - 1) * (height + BAR_GAP)))
    bar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -((index - 1) * (height + BAR_GAP)))
    bar:EnableMouse(true)
    bar:RegisterForClicks("LeftButtonUp")

    local statusBar = CreateFrame("StatusBar", nil, bar)
    statusBar:SetAllPoints(bar)
    statusBar:SetStatusBarTexture(CL.GetBarTexture())
    statusBar:SetMinMaxValues(0, 1)
    statusBar:SetValue(0)
    bar.statusBar = statusBar

    local bg = statusBar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(statusBar)
    bg:SetTexture(CL.GetBarTexture())
    bg:SetVertexColor(0.15, 0.15, 0.15, 0.85)
    bar.bg = bg

    local nameText = statusBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    nameText:SetPoint("LEFT", statusBar, "LEFT", 4, 0)
    nameText:SetJustifyH("LEFT")
    CL.ApplyFont(nameText, CL.GetFontSize())
    bar.nameText = nameText

    local valueText = statusBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    valueText:SetPoint("RIGHT", statusBar, "RIGHT", -4, 0)
    valueText:SetJustifyH("RIGHT")
    CL.ApplyFont(valueText, CL.GetFontSize())
    bar.valueText = valueText

    bar:SetScript("OnClick", function()
        if bar.guid and window and window.encounter and CL.UIBreakdown then
            CL.UIBreakdown.Show(bar.guid, window.metric, "history", window.encounter)
        end
    end)

    bar:Hide()
    return bar
end

local function RestyleReport()
    if not window then return end
    local r, g, b = CL.GetThemeColor()
    CL.ApplyWindowSkin(window, r, g, b, 0.85)
    CL.ApplyFont(window.title)
    CL.ApplyFont(window.subText)
    CL.ApplyFont(window.graphEmptyLabel)
    CL.ApplyFont(window.leaderEmptyLabel)
    CL.ApplyFont(window.graphPeakLabel)
    CL.ApplyFont(window.graphStartLabel)
    CL.ApplyFont(window.graphEndLabel)
    local height = CL.GetBarHeight(BAR_HEIGHT)
    CL.RepositionBarPool(leaderBars, height, BAR_GAP)
    local i
    for i = 1, table.getn(leaderBars) do
        leaderBars[i].statusBar:SetStatusBarTexture(CL.GetBarTexture())
        leaderBars[i].bg:SetTexture(CL.GetBarTexture())
        CL.ApplyFont(leaderBars[i].nameText, CL.GetFontSize())
        CL.ApplyFont(leaderBars[i].valueText, CL.GetFontSize())
    end
    for i = 1, table.getn(graphBars) do
        graphBars[i]:SetTexture(CL.GetBarTexture())
    end
end
CL.OnAppearanceChanged(RestyleReport)

local function CreateToggleButton(parent, metric, index)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetHeight(TOGGLE_HEIGHT)
    btn:SetWidth(70)
    btn:SetPoint("TOPLEFT", parent, "TOPLEFT", 6 + (index - 1) * 74, -HEADER_HEIGHT + 2)
    btn:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8", tile = false, tileSize = 0,
        edgeFile = "Interface\\BUTTONS\\WHITE8X8", edgeSize = 1,
        insets = { left = -1, right = -1, top = -1, bottom = -1 },
    })
    btn:SetBackdropColor(0.12, 0.12, 0.12, 0.8)
    local label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetAllPoints(btn)
    label:SetJustifyH("CENTER")
    label:SetText(METRIC_LABELS[metric])
    CL.ApplyFont(label)
    btn.label = label
    btn.metric = metric
    btn:SetScript("OnClick", function()
        if window then
            window.metric = btn.metric
            RC.Refresh()
        end
    end)
    return btn
end

local function CreateWindow()
    local f = CreateFrame("Frame", "CombatLedgerEncounterReportWindow", UIParent)
    f:SetWidth(WINDOW_WIDTH)
    f:SetHeight(WINDOW_HEIGHT)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetBackdrop(CL.WINDOW_BACKDROP)
    local themeR, themeG, themeB, themeHex = CL.GetThemeColor()
    f:SetBackdropColor(0, 0, 0, CL.GetBackdropAlpha(0.85))
    f:SetBackdropBorderColor(themeR, themeG, themeB, 1)
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() this:StartMoving() end)
    f:SetScript("OnDragStop", function()
        this:StopMovingOrSizing()
        CL.SaveLayout("encounterReport", this)
    end)
    f:Hide()

    CL.ApplyLayout("encounterReport", f, MIN_WINDOW_WIDTH, MIN_WINDOW_HEIGHT, MAX_WINDOW_WIDTH, MAX_WINDOW_HEIGHT)

    local alreadyRegistered = false
    local i
    for i = 1, table.getn(UISpecialFrames) do
        if UISpecialFrames[i] == "CombatLedgerEncounterReportWindow" then
            alreadyRegistered = true
        end
    end
    if not alreadyRegistered then
        table.insert(UISpecialFrames, "CombatLedgerEncounterReportWindow")
    end

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", f, "TOP", 0, -6)
    title:SetText("|cff" .. themeHex .. "Encounter Report|r")
    CL.ApplyFont(title)
    f.title = title

    local subText = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    subText:SetPoint("TOP", f, "TOP", 0, -20)
    CL.ApplyFont(subText)
    f.subText = subText

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetWidth(18)
    closeBtn:SetHeight(18)
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    for i = 1, table.getn(METRIC_ORDER) do
        toggleBtns[i] = CreateToggleButton(f, METRIC_ORDER[i], i)
    end

    local graphFrame = CreateFrame("Frame", nil, f)
    graphFrame:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -(HEADER_HEIGHT + TOGGLE_HEIGHT + 6))
    graphFrame:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -(HEADER_HEIGHT + TOGGLE_HEIGHT + 6))
    graphFrame:SetHeight(GRAPH_HEIGHT)
    graphFrame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        insets = { left = 0, right = 0, top = 0, bottom = 0 },
    })
    graphFrame:SetBackdropColor(0, 0, 0, 0.3)
    f.graphFrame = graphFrame

    for i = 1, GRAPH_BARS do
        graphBars[i] = CreateGraphBar(graphFrame)
    end

    -- Flat-indexed [ability][segment] pool, segment 1..GRAPH_BARS-1 (one
    -- fewer gap than points) - plain solid-color textures work fine here
    -- since every segment is axis-aligned (see the module comment above).
    local a, s
    for a = 1, MAX_GRAPH_ABILITIES do
        abilityLineH[a] = {}
        abilityLineV[a] = {}
        for s = 1, GRAPH_BARS - 1 do
            local h = graphFrame:CreateTexture(nil, "ARTWORK")
            h:SetTexture("Interface\\BUTTONS\\WHITE8X8")
            h:Hide()
            abilityLineH[a][s] = h
            local v = graphFrame:CreateTexture(nil, "ARTWORK")
            v:SetTexture("Interface\\BUTTONS\\WHITE8X8")
            v:Hide()
            abilityLineV[a][s] = v
        end
    end

    -- Axis context - without these, a bar/line's height and X position
    -- mean nothing to a reader who doesn't already know the fight's
    -- length and the metric's peak value at a glance. Peak sits inside
    -- the graph's top-right corner (it's what 100% bar/line height
    -- MEANS); start/end time sit inside the bottom corners.
    local peakLabel = graphFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    peakLabel:SetPoint("TOPRIGHT", graphFrame, "TOPRIGHT", -3, -2)
    CL.ApplyFont(peakLabel)
    f.graphPeakLabel = peakLabel

    local startTimeLabel = graphFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    startTimeLabel:SetPoint("BOTTOMLEFT", graphFrame, "BOTTOMLEFT", 3, 2)
    startTimeLabel:SetText("0:00")
    CL.ApplyFont(startTimeLabel)
    f.graphStartLabel = startTimeLabel

    local endTimeLabel = graphFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    endTimeLabel:SetPoint("BOTTOMRIGHT", graphFrame, "BOTTOMRIGHT", -3, 2)
    CL.ApplyFont(endTimeLabel)
    f.graphEndLabel = endTimeLabel

    -- One invisible hover column per graph slot, spanning the full graph
    -- height regardless of that column's actual bar/line height - a
    -- short bar is just as valid a hover target as a tall one. Each
    -- refresh repositions these and fills in tooltipTitle/tooltipLines;
    -- the actual GameTooltip display just reads whatever's there.
    for i = 1, GRAPH_BARS do
        local col = CreateFrame("Button", nil, graphFrame)
        col:EnableMouse(true)
        col:SetHeight(GRAPH_HEIGHT)
        col:Hide()
        col:SetScript("OnEnter", function()
            if not col.tooltipTitle then return end
            GameTooltip:SetOwner(col, "ANCHOR_TOP")
            GameTooltip:AddLine(col.tooltipTitle, 1, 0.82, 0)
            local j
            for j = 1, table.getn(col.tooltipLines or {}) do
                local line = col.tooltipLines[j]
                GameTooltip:AddDoubleLine(line.label, line.value, line.r or 1, line.g or 1, line.b or 1, 1, 1, 1)
            end
            GameTooltip:Show()
        end)
        col:SetScript("OnLeave", function() GameTooltip:Hide() end)
        graphHoverCols[i] = col
    end

    local graphEmpty = graphFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    graphEmpty:SetPoint("CENTER", graphFrame, "CENTER", 0, 0)
    graphEmpty:SetText("No timeline data")
    CL.ApplyFont(graphEmpty)
    f.graphEmptyLabel = graphEmpty

    local leaderLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    leaderLabel:SetPoint("TOPLEFT", graphFrame, "BOTTOMLEFT", 0, -LEADER_GAP_ABOVE)
    leaderLabel:SetText("Leaderboard")
    CL.ApplyFont(leaderLabel)
    f.leaderLabel = leaderLabel

    local leaderParent = CreateFrame("Frame", nil, f)
    leaderParent:SetPoint("TOPLEFT", leaderLabel, "BOTTOMLEFT", 0, -4)
    leaderParent:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, FOOTER_GAP)
    f.leaderParent = leaderParent

    for i = 1, MAX_LEADER_BARS do
        leaderBars[i] = CreateLeaderBar(leaderParent, i)
    end

    local leaderEmpty = leaderParent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    leaderEmpty:SetPoint("CENTER", leaderParent, "CENTER", 0, 0)
    leaderEmpty:SetText("No data")
    CL.ApplyFont(leaderEmpty)
    f.leaderEmptyLabel = leaderEmpty

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
        this.sizing = true
        this.startX, this.startY = GetCursorPosition()
        this.startW, this.startH = f:GetWidth(), f:GetHeight()
        this.scale = f:GetEffectiveScale()
    end)
    grip:SetScript("OnMouseUp", function()
        this.sizing = nil
        CL.SaveLayout("encounterReport", f)
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
        RC.Refresh()
    end)
    f.resizeGrip = grip

    CL.ApplyWindowSkin(f, themeR, themeG, themeB, 0.85)
    if pfUI and pfUI.api then
        pcall(pfUI.api.SkinCloseButton, closeBtn)
    end

    window = f
    window.metric = "damage"
    return f
end

-- Shared by both graph modes - positions/sizes the invisible hover
-- columns and fills in each one's tooltip content. `buildLines(i)`
-- returns that column's {label, value, r, g, b} rows; the time-range
-- title is the same shape for every mode so it's computed once here.
local function UpdateGraphHoverColumns(numPoints, secondsPerColumn, columnWidth, graphFrame, buildLines)
    local i
    for i = 1, GRAPH_BARS do
        local col = graphHoverCols[i]
        if i <= numPoints then
            col:ClearAllPoints()
            col:SetPoint("BOTTOMLEFT", graphFrame, "BOTTOMLEFT", (i - 1) * columnWidth, 0)
            col:SetWidth(columnWidth > 1 and columnWidth or 1)
            local startSec = (i - 1) * secondsPerColumn
            local endSec = i * secondsPerColumn
            col.tooltipTitle = "Time " .. FormatClock(startSec) .. " - " .. FormatClock(endSec)
            col.tooltipLines = buildLines(i)
            col:Show()
        else
            col.tooltipTitle = nil
            col:Hide()
        end
    end
end

local function HideAllAbilityLines()
    local a, s
    for a = 1, MAX_GRAPH_ABILITIES do
        for s = 1, GRAPH_BARS - 1 do
            abilityLineH[a][s]:Hide()
            abilityLineV[a][s]:Hide()
        end
    end
end

-- "Step" interpolation between adjacent points (flat at the earlier
-- point's height until the next column, then a vertical jump) drawn as
-- two axis-aligned rectangles - vanilla's Texture API has no rotation, so
-- a genuine diagonal line isn't an option without a much heavier
-- per-pixel/Bresenham approach. Reads clearly as "ability X's line" at
-- the point density GRAPH_BARS already gives every other graph here.
local function RefreshAbilityGraph(encounter, graphFrame, graphWidth)
    local top, maxRate, secondsPerColumn = BuildAbilityGraphSeries(encounter)
    window.abilitySeriesCache = top -- shared with RefreshLeaderboard so the legend matches these exact colors/ranks

    local numAbilities = table.getn(top)
    local numPoints = (numAbilities > 0) and table.getn(top[1].points) or 0

    if numPoints == 0 or maxRate <= 0 then
        -- Covers two different cases with one honest message: a genuine
        -- non-boss encounter (ability data was never collected for it),
        -- and a boss fight saved/tagged before this feature existed (see
        -- /cl tagboss - it flips isBossFight retroactively, but can't
        -- retroactively invent per-second ability data that was never
        -- recorded live).
        window.graphEmptyLabel:SetText(numAbilities == 0 and "No ability data recorded for this fight" or "No timeline data")
        window.graphEmptyLabel:Show()
        window.graphPeakLabel:SetText("")
        window.graphEndLabel:SetText("")
    else
        window.graphEmptyLabel:Hide()
        window.graphPeakLabel:SetText("Peak: " .. FormatNumber(maxRate) .. "/s")
        window.graphEndLabel:SetText(FormatClock(numPoints * secondsPerColumn))
    end

    UpdateGraphHoverColumns(numPoints, secondsPerColumn, graphWidth / ((numPoints > 0) and numPoints or 1), graphFrame, function(i)
        local lines = {}
        local a
        for a = 1, table.getn(top) do
            local ability = top[a]
            table.insert(lines, {
                label = ability.name,
                value = FormatNumber(ability.points[i]) .. "/s",
                r = ability.color[1], g = ability.color[2], b = ability.color[3],
            })
        end
        return lines
    end)

    local colWidth = graphWidth / ((numPoints > 0) and numPoints or 1)

    local a, i
    for a = 1, MAX_GRAPH_ABILITIES do
        local ability = top[a]
        for i = 1, GRAPH_BARS - 1 do
            local hTex, vTex = abilityLineH[a][i], abilityLineV[a][i]
            if ability and maxRate > 0 and i < numPoints then
                local p1, p2 = ability.points[i], ability.points[i + 1]
                local pct1 = p1 / maxRate
                local pct2 = p2 / maxRate
                if pct1 > 1 then pct1 = 1 end
                if pct2 > 1 then pct2 = 1 end
                local y1 = GRAPH_HEIGHT * pct1
                local y2 = GRAPH_HEIGHT * pct2
                local x1 = (i - 0.5) * colWidth
                local x2 = (i + 0.5) * colWidth
                local color = ability.color

                hTex:ClearAllPoints()
                hTex:SetPoint("BOTTOMLEFT", graphFrame, "BOTTOMLEFT", x1, y1 - LINE_THICKNESS / 2)
                hTex:SetWidth((x2 - x1) > 1 and (x2 - x1) or 1)
                hTex:SetHeight(LINE_THICKNESS)
                hTex:SetVertexColor(color[1], color[2], color[3], 0.95)
                hTex:Show()

                local vHeight = math.abs(y2 - y1)
                vTex:ClearAllPoints()
                vTex:SetPoint("BOTTOMLEFT", graphFrame, "BOTTOMLEFT", x2 - LINE_THICKNESS / 2, math.min(y1, y2))
                vTex:SetWidth(LINE_THICKNESS)
                vTex:SetHeight(vHeight > LINE_THICKNESS and vHeight or LINE_THICKNESS)
                vTex:SetVertexColor(color[1], color[2], color[3], 0.95)
                vTex:Show()
            else
                hTex:Hide()
                vTex:Hide()
            end
        end
    end
end

local function RefreshGraph()
    local encounter = window.encounter
    local graphFrame = window.graphFrame
    local graphWidth = graphFrame:GetWidth()

    if window.metric == "abilities" then
        local i
        for i = 1, GRAPH_BARS do graphBars[i]:Hide() end
        RefreshAbilityGraph(encounter, graphFrame, graphWidth)
        return
    end
    HideAllAbilityLines()

    local points, maxRate, secondsPerColumn = BuildGraphPoints(encounter, window.metric)
    local numPoints = table.getn(points)
    local color = METRIC_COLOR[window.metric]
    -- Stretch to fill the full width regardless of point count, so a
    -- short fight (fewer than GRAPH_BARS downsampled groups) still
    -- reads as a complete graph instead of a partial one hugging the
    -- left edge.
    local barWidth = graphWidth / ((numPoints > 0) and numPoints or 1)

    if numPoints == 0 then
        window.graphEmptyLabel:SetText("No timeline data")
        window.graphEmptyLabel:Show()
        window.graphPeakLabel:SetText("")
        window.graphEndLabel:SetText("")
    else
        window.graphEmptyLabel:Hide()
        window.graphPeakLabel:SetText("Peak: " .. FormatNumber(maxRate) .. " " .. CL.RateSuffix(window.metric))
        window.graphEndLabel:SetText(FormatClock(numPoints * secondsPerColumn))
    end

    local metricLabel = METRIC_LABELS[window.metric]
    local rateSuffix = CL.RateSuffix(window.metric)
    UpdateGraphHoverColumns(numPoints, secondsPerColumn, barWidth, graphFrame, function(i)
        return { { label = metricLabel, value = FormatNumber(points[i]) .. " " .. rateSuffix, r = color[1], g = color[2], b = color[3] } }
    end)

    local i
    for i = 1, GRAPH_BARS do
        local bar = graphBars[i]
        local value = (i <= numPoints) and points[i] or nil
        if value and maxRate > 0 then
            local pct = value / maxRate
            if pct > 1 then pct = 1 end
            if pct < 0.02 then pct = 0.02 end
            bar:ClearAllPoints()
            bar:SetPoint("BOTTOMLEFT", graphFrame, "BOTTOMLEFT", (i - 1) * barWidth, 0)
            bar:SetWidth(barWidth > 1 and (barWidth - 1) or 1)
            bar:SetHeight(GRAPH_HEIGHT * pct)
            bar:SetVertexColor(color[1], color[2], color[3], 0.9)
            bar:Show()
        else
            bar:Hide()
        end
    end
end

-- Doubles as the ability graph's legend in Abilities mode - reuses
-- window.abilitySeriesCache (set by RefreshAbilityGraph, which always
-- runs first in RC.Refresh) so the color swatch on each row is exactly
-- the color its line was actually drawn in, not a second independent
-- ranking that could disagree with a tie-break.
local function RefreshLeaderboard()
    local encounter = window.encounter

    if window.metric == "abilities" then
        local top = window.abilitySeriesCache or {}
        local maxVal = (top[1] and top[1].total) or 1
        local shown = 0
        local i
        for i = 1, MAX_LEADER_BARS do
            local bar = leaderBars[i]
            local entry = top[i]
            if entry then
                shown = shown + 1
                local color = entry.color or { 0.7, 0.7, 0.7 }
                bar.statusBar:SetStatusBarColor(color[1], color[2], color[3], 0.9)
                bar.statusBar:SetValue((maxVal > 0) and (entry.total / maxVal) or 0)
                bar.nameText:SetText(i .. ". " .. entry.name)
                bar.valueText:SetText(FormatNumber(entry.total))
                bar.guid = nil -- no per-player breakdown for an ability legend row
                bar:Show()
            else
                bar.guid = nil
                bar:Hide()
            end
        end
        if shown == 0 then
            window.leaderEmptyLabel:Show()
        else
            window.leaderEmptyLabel:Hide()
        end
        return
    end

    local field = METRIC_UNIT_FIELD[window.metric]
    local list = {}
    if encounter and encounter.units then
        local guid, u
        for guid, u in pairs(encounter.units) do
            local bucket = u[field]
            local total = (bucket and bucket.total) or 0
            if total > 0 then
                table.insert(list, { guid = guid, u = u, total = total })
            end
        end
    end
    table.sort(list, function(a, b) return a.total > b.total end)

    local maxVal = (list[1] and list[1].total) or 1
    local shown = 0
    local i
    for i = 1, MAX_LEADER_BARS do
        local bar = leaderBars[i]
        local entry = list[i]
        if entry then
            shown = shown + 1
            local r, g, b = ClassColorRGB(entry.u.classToken)
            bar.statusBar:SetStatusBarColor(r, g, b, 0.9)
            bar.statusBar:SetValue((maxVal > 0) and (entry.total / maxVal) or 0)
            local hex = ClassColorHex(entry.u.classToken)
            bar.nameText:SetText(i .. ". |cff" .. hex .. entry.u.name .. "|r")
            bar.valueText:SetText(FormatNumber(entry.total))
            bar.guid = entry.guid
            bar:Show()
        else
            bar.guid = nil
            bar:Hide()
        end
    end

    if shown == 0 then
        window.leaderEmptyLabel:Show()
    else
        window.leaderEmptyLabel:Hide()
    end
end

function RC.Refresh()
    if not window or not window:IsShown() or not window.encounter then return end

    local enc = window.encounter
    local themeR, themeG, themeB, themeHex = CL.GetThemeColor()
    window.title:SetText("|cff" .. themeHex .. (enc.label or "Encounter") .. "|r")

    local durText = string.format("%.0fs", enc.duration or 0)
    local zoneText = enc.zone or ""
    local pullText = (enc.pullBy and enc.pullBy.name) and (" - pulled by " .. enc.pullBy.name) or ""
    window.subText:SetText(zoneText .. "  -  " .. durText .. pullText)

    local i
    for i = 1, table.getn(toggleBtns) do
        local btn = toggleBtns[i]
        if btn.metric == window.metric then
            btn:SetBackdropColor(themeR, themeG, themeB, 0.5)
        else
            btn:SetBackdropColor(0.12, 0.12, 0.12, 0.8)
        end
    end

    window.leaderLabel:SetText((window.metric == "abilities") and "Legend" or "Leaderboard")

    RefreshGraph()
    RefreshLeaderboard()
end

function RC.Show(encounter)
    if not encounter then return end
    if not window then CreateWindow() end
    window.encounter = encounter
    window:Show()
    RC.Refresh()
end

function RC.Hide()
    if window then window:Hide() end
end
