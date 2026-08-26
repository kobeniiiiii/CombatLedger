--[[
    UI_DeathRecap - "what actually killed me". Opens automatically on the
    player's own death (see Events.lua's UNIT_DIED handler), showing the
    exact sequence of hits in the last few seconds before it, newest
    first. Static once shown - it's a recap of something that already
    happened, not a live view, so unlike the other windows this has no
    refresh driver.
]]

local CL = CombatLedger
local RC = {}
CL.UIDeathRecap = RC

local MAX_BARS = 15
local BAR_HEIGHT = 16
local BAR_GAP = 2
local HEADER_HEIGHT = 26
local FOOTER_GAP = 12

local WINDOW_WIDTH, WINDOW_HEIGHT = 280, 220
local MIN_WINDOW_WIDTH, MIN_WINDOW_HEIGHT = 200, 100
local MAX_WINDOW_WIDTH, MAX_WINDOW_HEIGHT = 500, 600

local window = nil
local bars = {}

local function FormatNumber(n)
    return CL.FormatNumber(n)
end

local function ClassColorHex(classToken)
    if classToken and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken] then
        local c = RAID_CLASS_COLORS[classToken]
        return string.format("%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
    end
    return "ffffff"
end

local function CreateBar(parent, index)
    local height = CL.GetBarHeight(BAR_HEIGHT)
    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetHeight(height)
    bar:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -((index - 1) * (height + BAR_GAP)))
    bar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -((index - 1) * (height + BAR_GAP)))
    bar:SetStatusBarTexture(CL.GetBarTexture())
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    bar:SetStatusBarColor(0.85, 0.2, 0.2, 0.9)

    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(bar)
    bg:SetTexture(CL.GetBarTexture())
    bg:SetVertexColor(0.15, 0.15, 0.15, 0.85)
    bar.bg = bg

    local nameText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    nameText:SetPoint("LEFT", bar, "LEFT", 4, 0)
    nameText:SetJustifyH("LEFT")
    nameText:SetText("")
    CL.ApplyFont(nameText, CL.GetFontSize())
    bar.nameText = nameText

    local valueText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    valueText:SetPoint("RIGHT", bar, "RIGHT", -4, 0)
    valueText:SetJustifyH("RIGHT")
    valueText:SetText("")
    CL.ApplyFont(valueText, CL.GetFontSize())
    bar.valueText = valueText

    bar:Hide()
    return bar
end

local function RestyleBars()
    if not window then return end
    CL.ApplyWindowSkin(window, 0.85, 0.2, 0.2, 0.85)
    CL.ApplyFont(window.title)
    CL.ApplyFont(window.emptyLabel)
    local height = CL.GetBarHeight(BAR_HEIGHT)
    CL.RepositionBarPool(bars, height, BAR_GAP)
    local i
    for i = 1, table.getn(bars) do
        bars[i]:SetStatusBarTexture(CL.GetBarTexture())
        bars[i].bg:SetTexture(CL.GetBarTexture())
        CL.ApplyFont(bars[i].nameText, CL.GetFontSize())
        CL.ApplyFont(bars[i].valueText, CL.GetFontSize())
    end
end
CL.OnAppearanceChanged(RestyleBars)

local function CreateWindow()
    local f = CreateFrame("Frame", "CombatLedgerDeathRecapWindow", UIParent)
    f:SetWidth(WINDOW_WIDTH)
    f:SetHeight(WINDOW_HEIGHT)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 150)
    f:SetBackdrop(CL.WINDOW_BACKDROP)
    f:SetBackdropColor(0, 0, 0, CL.GetBackdropAlpha(0.85))
    f:SetBackdropBorderColor(0.85, 0.2, 0.2, 1)
    -- MEDIUM, same tier as the meter window itself (see UI_MainWindow.
    -- lua's CreateWindowFrame) - HIGH still rendered above Blizzard's
    -- own Character/Bags/Quest-dialog panels on this client, same as
    -- DIALOG did before that.
    f:SetFrameStrata("MEDIUM")
    -- See UI_Options.lua's own comment on this - without it, whichever
    -- window got a structurally higher frame level at creation time
    -- permanently renders in front of every other "MEDIUM" window,
    -- regardless of which was actually opened/clicked last.
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() this:StartMoving() end)
    f:SetScript("OnDragStop", function()
        this:StopMovingOrSizing()
        CL.SaveLayout("deathRecap", this)
    end)
    f:Hide()

    CL.ApplyLayout("deathRecap", f, MIN_WINDOW_WIDTH, MIN_WINDOW_HEIGHT, MAX_WINDOW_WIDTH, MAX_WINDOW_HEIGHT)

    local alreadyRegistered = false
    local i
    for i = 1, table.getn(UISpecialFrames) do
        if UISpecialFrames[i] == "CombatLedgerDeathRecapWindow" then
            alreadyRegistered = true
        end
    end
    if not alreadyRegistered then
        table.insert(UISpecialFrames, "CombatLedgerDeathRecapWindow")
    end

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", f, "TOP", 0, -6)
    title:SetText("|cffff4040Death Recap|r")
    CL.ApplyFont(title)
    f.title = title

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetWidth(18)
    closeBtn:SetHeight(18)
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    local barParent = CreateFrame("Frame", nil, f)
    barParent:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -HEADER_HEIGHT)
    barParent:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, FOOTER_GAP)
    f.barParent = barParent

    for i = 1, MAX_BARS do
        bars[i] = CreateBar(barParent, i)
    end

    local empty = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    empty:SetPoint("CENTER", barParent, "CENTER", 0, 0)
    empty:SetText("No recorded hits")
    CL.ApplyFont(empty)
    f.emptyLabel = empty

    local grip = CreateFrame("Button", nil, f)
    grip:SetWidth(16)
    grip:SetHeight(16)
    grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
    grip:SetFrameLevel(f:GetFrameLevel() + 10)
    grip:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
    grip:SetBackdropColor(0.85, 0.2, 0.2, 0.4)
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
        CL.SaveLayout("deathRecap", f)
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
    end)
    f.resizeGrip = grip

    CL.ApplyWindowSkin(f, 0.85, 0.2, 0.2, 0.85)
    if pfUI and pfUI.api then
        pcall(pfUI.api.SkinCloseButton, closeBtn)
    end

    window = f
    return f
end

function RC.Show(guid)
    if not guid then return end
    local recap = CL.Aggregator.GetDeathRecap(guid)
    if not window then CreateWindow() end

    local info = CL.GuidCache and CL.GuidCache.Resolve(guid)
    local name = (info and info.name) or "Unknown"
    local classHex = ClassColorHex(info and info.classToken)
    window.title:SetText("|cffff4040Death Recap|r  |cff" .. classHex .. name .. "|r")

    local hits = (recap and recap.hits) or {}
    local deathTime = recap and recap.deathTime or GetTime()

    local maxVal = 1
    local i
    for i = 1, table.getn(hits) do
        if hits[i].amount > maxVal then maxVal = hits[i].amount end
    end

    local total = table.getn(hits)
    local shown = 0
    for i = 1, MAX_BARS do
        local bar = bars[i]
        -- newest first: last entry in `hits` (chronological) is index 1 here
        local srcIndex = total - i + 1
        local entry = (srcIndex >= 1) and hits[srcIndex] or nil
        if entry then
            shown = shown + 1
            local pct = entry.amount / maxVal
            if pct > 1 then pct = 1 end
            bar:SetValue(pct)
            local offset = entry.time - deathTime
            bar.nameText:SetText(string.format("%.1fs  %s (%s)", offset, entry.attacker, entry.label))
            bar.valueText:SetText(FormatNumber(entry.amount) .. (entry.isCrit and "  |cffff4040CRIT|r" or ""))
            bar:Show()
        else
            bar:Hide()
        end
    end

    if shown == 0 then
        window.emptyLabel:Show()
    else
        window.emptyLabel:Hide()
    end

    window:Show()
end

function RC.Hide()
    if window then window:Hide() end
end
