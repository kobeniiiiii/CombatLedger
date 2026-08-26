--[[
    UI_Options - one flat window for everything this addon actually has
    to configure (lock/minimap/appearance/timing), not an attempt at
    Details' full skin/profile/automation system. Opened via the main
    window's "Opt" button, the minimap button's right-click, or
    /cl options.

    Also owns the minimap button (LootLedger's CreateMinimapButton
    pattern - draggable icon around the ring, position saved to
    CombatLedgerDB.minimapAngle) since Options is what controls whether
    it's shown.
]]

local CL = CombatLedger
local OPT = {}
CL.UIOptions = OPT

-- WINDOW_HEIGHT fits the Advanced tab's worst case (every row slot
-- full - 3 NextY() lines each: name/close, show/hide/grouped toggles,
-- mirror button) plus bottom padding - see the row-building loop below.
-- RefreshOptionsWindow reflows resetPosBtn up to sit right after
-- however many windows actually exist, so this is a ceiling, not what
-- most people will actually see below their last row.
local WINDOW_WIDTH, WINDOW_HEIGHT = 300, 628 -- +24 over the prior ceiling for the "Ask before clearing" row (join-party clear is now two checkboxes, not one)
local MAX_WINDOW_ROWS = 4 -- most people won't run more than 2-3 extra meter windows at once
local ROW_HEIGHT = 24

local window = nil
local minimapButton = nil

--------------------------------------------------------------------------
-- Small reusable controls
--------------------------------------------------------------------------

local function CreateSmallButton(parent, width, text)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetWidth(width)
    btn:SetHeight(18)
    btn:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8", tile = false, tileSize = 0,
        edgeFile = "Interface\\BUTTONS\\WHITE8X8", edgeSize = 1,
        insets = { left = -1, right = -1, top = -1, bottom = -1 },
    })
    btn:SetBackdropColor(0.15, 0.15, 0.15, 0.75)
    btn:SetBackdropBorderColor(CL.FLAT_BORDER_R, CL.FLAT_BORDER_G, CL.FLAT_BORDER_B, 1)
    local label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetAllPoints(btn)
    label:SetJustifyH("CENTER")
    label:SetText(text or "")
    btn.label = label
    return btn
end

-- Small color-preview swatch, anchored to the left of a checkbox - click
-- opens Blizzard's own ColorPickerFrame, previews the live selection as
-- it changes, and reverts to whatever it was on Cancel (its own Cancel
-- button, or closing the picker without confirming), same as every
-- other Blizzard color picker use. Shared by "Highlight my bar" and
-- "Show bar border" below, which each just pass their own settingKey.
local function CreateColorSwatch(parent, anchorCB, settingKey, tooltipText)
    local swatch = CreateFrame("Button", nil, parent)
    swatch:SetWidth(16)
    swatch:SetHeight(16)
    swatch:SetPoint("RIGHT", anchorCB, "LEFT", -8, 0)
    swatch:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1,
        insets = { left = -1, right = -1, top = -1, bottom = -1 },
    })
    swatch:SetBackdropBorderColor(CL.FLAT_BORDER_R, CL.FLAT_BORDER_G, CL.FLAT_BORDER_B, 1)
    swatch:SetScript("OnClick", function()
        local color = CL.GetSetting(settingKey)
        local origR, origG, origB = color[1], color[2], color[3]
        ColorPickerFrame.func = function()
            local r, g, b = ColorPickerFrame:GetColorRGB()
            CL.SetSetting(settingKey, { r, g, b })
            swatch:SetBackdropColor(r, g, b, 1)
            if CL.UI and CL.UI.Refresh then CL.UI.Refresh() end
        end
        ColorPickerFrame.cancelFunc = function()
            CL.SetSetting(settingKey, { origR, origG, origB })
            swatch:SetBackdropColor(origR, origG, origB, 1)
            if CL.UI and CL.UI.Refresh then CL.UI.Refresh() end
        end
        ColorPickerFrame.hasOpacity = nil
        ColorPickerFrame:SetColorRGB(origR, origG, origB)
        ShowUIPanel(ColorPickerFrame)
    end)
    swatch:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_LEFT")
        GameTooltip:SetText(tooltipText)
        GameTooltip:Show()
    end)
    swatch:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return swatch
end

-- +/- stepper - value display flanked by two small buttons, all anchored
-- as one unit off the row's TOPRIGHT.
local function CreateStepper(parent, width)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetWidth(width)
    holder:SetHeight(18)

    local minus = CreateSmallButton(holder, 16, "-")
    minus:SetPoint("LEFT", holder, "LEFT", 0, 0)

    local plus = CreateSmallButton(holder, 16, "+")
    plus:SetPoint("RIGHT", holder, "RIGHT", 0, 0)

    local value = holder:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    value:SetPoint("LEFT", minus, "RIGHT", 2, 0)
    value:SetPoint("RIGHT", plus, "LEFT", -2, 0)
    value:SetJustifyH("CENTER")

    holder.minus = minus
    holder.plus = plus
    holder.value = value
    return holder
end

local function SetControlEnabled(ctrl, enabled)
    ctrl:SetAlpha(enabled and 1 or 0.4)
    if ctrl.EnableMouse then ctrl:EnableMouse(enabled) end
    if ctrl.minus then
        ctrl.minus:EnableMouse(enabled)
        ctrl.plus:EnableMouse(enabled)
    end
end

local function CycleKey(list, currentKey)
    local i
    for i = 1, table.getn(list) do
        if list[i].key == currentKey then
            local nextIndex = i + 1
            if nextIndex > table.getn(list) then nextIndex = 1 end
            return list[nextIndex].key
        end
    end
    return list[1] and list[1].key
end

local function LabelForKey(list, key)
    local i
    for i = 1, table.getn(list) do
        if list[i].key == key then return list[i].label end
    end
    return "?"
end

--------------------------------------------------------------------------
-- Options window
--------------------------------------------------------------------------

local RefreshOptionsWindow -- forward-declared, assigned below

local function CreateWindow()
    local f = CreateFrame("Frame", "CombatLedgerOptionsWindow", UIParent)
    f:SetWidth(WINDOW_WIDTH)
    f:SetHeight(WINDOW_HEIGHT)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetBackdrop(CL.WINDOW_BACKDROP)
    f:SetBackdropColor(0, 0, 0, 0.9)
    local themeR, themeG, themeB, themeHex = CL.GetThemeColor()
    f:SetBackdropBorderColor(CL.FLAT_BORDER_R, CL.FLAT_BORDER_G, CL.FLAT_BORDER_B, 1)
    -- MEDIUM, same tier as the meter window itself (see UI_MainWindow.
    -- lua's CreateWindowFrame) - HIGH still rendered above Blizzard's
    -- own Character/Bags/Quest-dialog panels on this client, same as
    -- DIALOG did before that.
    f:SetFrameStrata("MEDIUM")
    -- Without this, whichever CombatLedger window happened to get a
    -- structurally higher frame level at creation time permanently
    -- renders in front of every other "MEDIUM" window regardless of
    -- which one was actually opened/clicked last - none of these
    -- draggable windows called SetToplevel/Raise anywhere, so their
    -- front-to-back order within the strata never changed after
    -- creation. SetToplevel makes the engine auto-raise this frame
    -- within its strata whenever it receives mouse focus, same as
    -- Blizzard's own floating panels (CharacterFrame, etc).
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() this:StartMoving() end)
    f:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
    f:Hide()

    table.insert(UISpecialFrames, "CombatLedgerOptionsWindow")

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", f, "TOP", 0, -10)
    title:SetText("|cff" .. themeHex .. "CombatLedger Options|r")

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetWidth(18)
    closeBtn:SetHeight(18)
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    -- Two tabs instead of one long scroll of sections - General (window
    -- behavior/appearance/bar animation) and Advanced (timing/announce/
    -- windows). Same "avoid Blizzard's heavier templates" reasoning as
    -- the rest of this addon's UI (ShowDropdown instead of
    -- UIDropDownMenu, etc) - two plain buttons + two content frames
    -- toggled together, not a real TabButtonTemplate strip.
    local pageGeneral = CreateFrame("Frame", nil, f)
    pageGeneral:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    pageGeneral:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    local pageAdvanced = CreateFrame("Frame", nil, f)
    pageAdvanced:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    pageAdvanced:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)

    local tabGeneralBtn = CreateSmallButton(f, (WINDOW_WIDTH - 32) / 2, "General")
    tabGeneralBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -32)
    local tabAdvancedBtn = CreateSmallButton(f, (WINDOW_WIDTH - 32) / 2, "Advanced")
    tabAdvancedBtn:SetPoint("LEFT", tabGeneralBtn, "RIGHT", 4, 0)

    local function ShowTab(tab)
        if tab == "advanced" then
            pageGeneral:Hide()
            pageAdvanced:Show()
            tabGeneralBtn:SetBackdropColor(0.15, 0.15, 0.15, 0.75)
            tabAdvancedBtn:SetBackdropColor(0.3, 0.25, 0.4, 0.9)
        else
            pageAdvanced:Hide()
            pageGeneral:Show()
            tabAdvancedBtn:SetBackdropColor(0.15, 0.15, 0.15, 0.75)
            tabGeneralBtn:SetBackdropColor(0.3, 0.25, 0.4, 0.9)
        end
    end
    tabGeneralBtn:SetScript("OnClick", function() ShowTab("general") end)
    tabAdvancedBtn:SetScript("OnClick", function() ShowTab("advanced") end)
    f.tabGeneralBtn = tabGeneralBtn
    f.tabAdvancedBtn = tabAdvancedBtn

    local yOffset = 60
    local function NextY()
        local y = yOffset
        yOffset = yOffset + ROW_HEIGHT
        return y
    end

    -- Thin separator line between sections - a plain colored header on
    -- its own reads weakly at this compact size, easy to skim past.
    -- Advances yOffset by less than a full row (this isn't a control,
    -- it doesn't need one's worth of breathing room on both sides).
    local function AddDivider(parent)
        local line = parent:CreateTexture(nil, "ARTWORK")
        line:SetTexture("Interface\\Buttons\\WHITE8X8")
        line:SetVertexColor(1, 1, 1, 0.12)
        line:SetHeight(1)
        line:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, -yOffset)
        line:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -12, -yOffset)
        yOffset = yOffset + 10
    end

    -- Window behavior
    local lockLabel = pageGeneral:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    local y = NextY()
    lockLabel:SetPoint("TOPLEFT", pageGeneral, "TOPLEFT", 14, -y)
    lockLabel:SetText("Lock windows")
    local lockCB = CreateFrame("CheckButton", "CombatLedgerLockCB", pageGeneral, "UICheckButtonTemplate")
    lockCB:SetWidth(20)
    lockCB:SetHeight(20)
    lockCB:SetPoint("TOPRIGHT", pageGeneral, "TOPRIGHT", -12, -y + 3)
    lockCB:SetScript("OnClick", function()
        CL.SetSetting("lockWindow", (this:GetChecked() == 1))
        CL.FireAppearanceChanged()
    end)
    f.lockCB = lockCB

    local minimapLabel = pageGeneral:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    y = NextY()
    minimapLabel:SetPoint("TOPLEFT", pageGeneral, "TOPLEFT", 14, -y)
    minimapLabel:SetText("Show minimap button")
    local minimapCB = CreateFrame("CheckButton", "CombatLedgerMinimapCB", pageGeneral, "UICheckButtonTemplate")
    minimapCB:SetWidth(20)
    minimapCB:SetHeight(20)
    minimapCB:SetPoint("TOPRIGHT", pageGeneral, "TOPRIGHT", -12, -y + 3)
    minimapCB:SetScript("OnClick", function()
        CL.SetSetting("showMinimapButton", (this:GetChecked() == 1))
        OPT.RefreshMinimapVisibility()
    end)
    f.minimapCB = minimapCB

    -- Auto-show/auto-hide used to be global checkboxes here - now
    -- per-window (see the Windows section on the Advanced tab), since a
    -- Threat meter and an always-on Damage meter want different rules.

    -- Appearance
    AddDivider(pageGeneral)
    local appearanceHeader = pageGeneral:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    y = NextY()
    appearanceHeader:SetPoint("TOPLEFT", pageGeneral, "TOPLEFT", 14, -y)
    appearanceHeader:SetText("|cffffd700Appearance|r")

    local matchPfuiCB
    if CL.HasPfui() then
        local matchLabel = pageGeneral:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        y = NextY()
        matchLabel:SetPoint("TOPLEFT", pageGeneral, "TOPLEFT", 14, -y)
        matchLabel:SetText("Match pfUI (texture + font)")
        matchPfuiCB = CreateFrame("CheckButton", "CombatLedgerMatchPfuiCB", pageGeneral, "UICheckButtonTemplate")
        matchPfuiCB:SetWidth(20)
        matchPfuiCB:SetHeight(20)
        matchPfuiCB:SetPoint("TOPRIGHT", pageGeneral, "TOPRIGHT", -12, -y + 3)
        matchPfuiCB:SetScript("OnClick", function()
            CL.SetSetting("matchPfui", (this:GetChecked() == 1))
            CL.FireAppearanceChanged()
            RefreshOptionsWindow()
        end)
    end
    f.matchPfuiCB = matchPfuiCB

    -- "Dock in pfUI chat panel" removed for now - the dock never worked
    -- reliably and isn't worth fixing right now. UI_PfuiDock.lua itself
    -- is untouched (still there if this gets revisited later), just
    -- unreachable from Options now - pfuiDock stays false forever with
    -- no control to flip it.

    local textureLabel = pageGeneral:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    y = NextY()
    textureLabel:SetPoint("TOPLEFT", pageGeneral, "TOPLEFT", 14, -y)
    textureLabel:SetText("Bar texture")
    local textureBtn = CreateSmallButton(pageGeneral, 130, "")
    textureBtn:SetPoint("TOPRIGHT", pageGeneral, "TOPRIGHT", -12, -y + 1)
    textureBtn:SetScript("OnClick", function()
        local list = CL.GetAvailableBarTextures()
        local options = {}
        local i
        for i = 1, table.getn(list) do
            local key = list[i].key
            table.insert(options, { label = list[i].label, onClick = function()
                CL.SetSetting("barTexture", key)
                CL.FireAppearanceChanged()
                RefreshOptionsWindow()
            end })
        end
        CL.ShowDropdown(textureBtn, options)
    end)
    f.textureBtn = textureBtn

    -- ShaguDPS-style borderless window - independent of Match pfUI (see
    -- CL.ApplyWindowSkin's hideBorder branch).
    local hideBorderLabel = pageGeneral:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    y = NextY()
    hideBorderLabel:SetPoint("TOPLEFT", pageGeneral, "TOPLEFT", 14, -y)
    hideBorderLabel:SetText("Hide window border")
    local hideBorderCB = CreateFrame("CheckButton", "CombatLedgerHideBorderCB", pageGeneral, "UICheckButtonTemplate")
    hideBorderCB:SetWidth(20)
    hideBorderCB:SetHeight(20)
    hideBorderCB:SetPoint("TOPRIGHT", pageGeneral, "TOPRIGHT", -12, -y + 3)
    hideBorderCB:SetScript("OnClick", function()
        CL.SetSetting("hideBorder", (this:GetChecked() == 1))
        CL.FireAppearanceChanged()
    end)
    f.hideBorderCB = hideBorderCB

    -- Class icon before the name on each bar - separate from bar fill
    -- color (which is already class-colored), just an extra visual cue
    -- some people want and others find redundant, hence opt-in.
    local classIconLabel = pageGeneral:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    y = NextY()
    classIconLabel:SetPoint("TOPLEFT", pageGeneral, "TOPLEFT", 14, -y)
    classIconLabel:SetText("Show class icon")
    local classIconCB = CreateFrame("CheckButton", "CombatLedgerClassIconCB", pageGeneral, "UICheckButtonTemplate")
    classIconCB:SetWidth(20)
    classIconCB:SetHeight(20)
    classIconCB:SetPoint("TOPRIGHT", pageGeneral, "TOPRIGHT", -12, -y + 3)
    classIconCB:SetScript("OnClick", function()
        CL.SetSetting("showClassIcon", (this:GetChecked() == 1))
        if CL.UI and CL.UI.Refresh then CL.UI.Refresh() end
    end)
    f.classIconCB = classIconCB

    -- Border around whichever bar is the player's own, in
    -- highlightSelfColor, so it's obvious at a glance which row is you
    -- without reading every name.
    local highlightSelfLabel = pageGeneral:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    y = NextY()
    highlightSelfLabel:SetPoint("TOPLEFT", pageGeneral, "TOPLEFT", 14, -y)
    highlightSelfLabel:SetText("Highlight my bar")
    local highlightSelfCB = CreateFrame("CheckButton", "CombatLedgerHighlightSelfCB", pageGeneral, "UICheckButtonTemplate")
    highlightSelfCB:SetWidth(20)
    highlightSelfCB:SetHeight(20)
    highlightSelfCB:SetPoint("TOPRIGHT", pageGeneral, "TOPRIGHT", -12, -y + 3)
    highlightSelfCB:SetScript("OnClick", function()
        CL.SetSetting("highlightSelf", (this:GetChecked() == 1))
        if CL.UI and CL.UI.Refresh then CL.UI.Refresh() end
    end)
    f.highlightSelfCB = highlightSelfCB
    f.highlightSelfSwatch = CreateColorSwatch(pageGeneral, highlightSelfCB, "highlightSelfColor", "Click to choose the highlight color")

    -- Border around EVERY bar, independent of Highlight my bar above -
    -- that one always wins gold on your own row regardless of this
    -- setting/color. Color is user-pickable via Blizzard's own
    -- ColorPickerFrame - the swatch button previews the current choice.
    local barBorderLabel = pageGeneral:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    y = NextY()
    barBorderLabel:SetPoint("TOPLEFT", pageGeneral, "TOPLEFT", 14, -y)
    barBorderLabel:SetText("Show bar border")
    local barBorderCB = CreateFrame("CheckButton", "CombatLedgerBarBorderCB", pageGeneral, "UICheckButtonTemplate")
    barBorderCB:SetWidth(20)
    barBorderCB:SetHeight(20)
    barBorderCB:SetPoint("TOPRIGHT", pageGeneral, "TOPRIGHT", -12, -y + 3)
    barBorderCB:SetScript("OnClick", function()
        CL.SetSetting("barBorderEnabled", (this:GetChecked() == 1))
        if CL.UI and CL.UI.Refresh then CL.UI.Refresh() end
    end)
    f.barBorderCB = barBorderCB
    f.barBorderSwatch = CreateColorSwatch(pageGeneral, barBorderCB, "barBorderColor", "Click to choose the border color")

    -- Header/dropdown buttons take the player's class color instead of
    -- the flat near-black default - independent of the class icon above
    -- (this is chrome/border color, not an icon).
    local classColorLabel = pageGeneral:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    y = NextY()
    classColorLabel:SetPoint("TOPLEFT", pageGeneral, "TOPLEFT", 14, -y)
    classColorLabel:SetText("Class colored menus")
    local classColorCB = CreateFrame("CheckButton", "CombatLedgerClassColorCB", pageGeneral, "UICheckButtonTemplate")
    classColorCB:SetWidth(20)
    classColorCB:SetHeight(20)
    classColorCB:SetPoint("TOPRIGHT", pageGeneral, "TOPRIGHT", -12, -y + 3)
    classColorCB:SetScript("OnClick", function()
        CL.SetSetting("classColorMenus", (this:GetChecked() == 1))
        CL.FireAppearanceChanged()
    end)
    f.classColorCB = classColorCB

    local fontLabel = pageGeneral:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    y = NextY()
    fontLabel:SetPoint("TOPLEFT", pageGeneral, "TOPLEFT", 14, -y)
    fontLabel:SetText("Font")
    local fontBtn = CreateSmallButton(pageGeneral, 130, "")
    fontBtn:SetPoint("TOPRIGHT", pageGeneral, "TOPRIGHT", -12, -y + 1)
    fontBtn:SetScript("OnClick", function()
        local options = {}
        local i
        for i = 1, table.getn(CL.FONTS) do
            local key = CL.FONTS[i].key
            table.insert(options, { label = CL.FONTS[i].label, onClick = function()
                CL.SetSetting("fontKey", key)
                CL.FireAppearanceChanged()
                RefreshOptionsWindow()
            end })
        end
        CL.ShowDropdown(fontBtn, options)
    end)
    f.fontBtn = fontBtn

    local fontSizeLabel = pageGeneral:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    y = NextY()
    fontSizeLabel:SetPoint("TOPLEFT", pageGeneral, "TOPLEFT", 14, -y)
    fontSizeLabel:SetText("Font size")
    local fontSizeStepper = CreateStepper(pageGeneral, 90)
    fontSizeStepper:SetPoint("TOPRIGHT", pageGeneral, "TOPRIGHT", -12, -y + 1)
    fontSizeStepper.minus:SetScript("OnClick", function()
        local v = (CL.GetSetting("fontSize") or 10) - 1
        if v < 8 then v = 8 end
        CL.SetSetting("fontSize", v)
        CL.FireAppearanceChanged()
        RefreshOptionsWindow()
    end)
    fontSizeStepper.plus:SetScript("OnClick", function()
        local v = (CL.GetSetting("fontSize") or 10) + 1
        if v > 18 then v = 18 end
        CL.SetSetting("fontSize", v)
        CL.FireAppearanceChanged()
        RefreshOptionsWindow()
    end)
    f.fontSizeStepper = fontSizeStepper

    local barHeightLabel = pageGeneral:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    y = NextY()
    barHeightLabel:SetPoint("TOPLEFT", pageGeneral, "TOPLEFT", 14, -y)
    barHeightLabel:SetText("Bar size")
    local barHeightStepper = CreateStepper(pageGeneral, 90)
    barHeightStepper:SetPoint("TOPRIGHT", pageGeneral, "TOPRIGHT", -12, -y + 1)
    barHeightStepper.minus:SetScript("OnClick", function()
        local v = CL.GetSetting("barHeight") or 18
        v = v - 1
        if v < 10 then v = 10 end
        CL.SetSetting("barHeight", v)
        CL.FireAppearanceChanged()
        RefreshOptionsWindow()
    end)
    barHeightStepper.plus:SetScript("OnClick", function()
        local v = CL.GetSetting("barHeight") or 18
        v = v + 1
        if v > 32 then v = 32 end
        CL.SetSetting("barHeight", v)
        CL.FireAppearanceChanged()
        RefreshOptionsWindow()
    end)
    f.barHeightStepper = barHeightStepper

    local numberFmtLabel = pageGeneral:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    y = NextY()
    numberFmtLabel:SetPoint("TOPLEFT", pageGeneral, "TOPLEFT", 14, -y)
    numberFmtLabel:SetText("Number format")
    local numberFmtBtn = CreateSmallButton(pageGeneral, 130, "")
    numberFmtBtn:SetPoint("TOPRIGHT", pageGeneral, "TOPRIGHT", -12, -y + 1)
    numberFmtBtn:SetScript("OnClick", function()
        local options = {}
        local i
        for i = 1, table.getn(CL.NUMBER_FORMATS) do
            local key = CL.NUMBER_FORMATS[i].key
            table.insert(options, { label = CL.NUMBER_FORMATS[i].label, onClick = function()
                CL.SetSetting("numberFormat", key)
                CL.FireAppearanceChanged()
                RefreshOptionsWindow()
            end })
        end
        CL.ShowDropdown(numberFmtBtn, options)
    end)
    f.numberFmtBtn = numberFmtBtn

    local opacityLabel = pageGeneral:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    y = NextY()
    opacityLabel:SetPoint("TOPLEFT", pageGeneral, "TOPLEFT", 14, -y)
    opacityLabel:SetText("Window opacity")
    local opacityStepper = CreateStepper(pageGeneral, 90)
    opacityStepper:SetPoint("TOPRIGHT", pageGeneral, "TOPRIGHT", -12, -y + 1)
    opacityStepper.minus:SetScript("OnClick", function()
        local v = (CL.GetSetting("windowOpacityPct") or 81) - 5
        if v < 0 then v = 0 end
        CL.SetSetting("windowOpacityPct", v)
        CL.FireAppearanceChanged()
        RefreshOptionsWindow()
    end)
    opacityStepper.plus:SetScript("OnClick", function()
        local v = (CL.GetSetting("windowOpacityPct") or 85) + 5
        if v > 100 then v = 100 end
        CL.SetSetting("windowOpacityPct", v)
        CL.FireAppearanceChanged()
        RefreshOptionsWindow()
    end)
    f.opacityStepper = opacityStepper

    -- Bar animation
    AddDivider(pageGeneral)
    local animHeader = pageGeneral:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    y = NextY()
    animHeader:SetPoint("TOPLEFT", pageGeneral, "TOPLEFT", 14, -y)
    animHeader:SetText("|cffffd700Bar Animation|r")

    local smoothLabel = pageGeneral:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    y = NextY()
    smoothLabel:SetPoint("TOPLEFT", pageGeneral, "TOPLEFT", 14, -y)
    smoothLabel:SetText("Smooth bars (main window)")
    local smoothCB = CreateFrame("CheckButton", "CombatLedgerSmoothCB", pageGeneral, "UICheckButtonTemplate")
    smoothCB:SetWidth(20)
    smoothCB:SetHeight(20)
    smoothCB:SetPoint("TOPRIGHT", pageGeneral, "TOPRIGHT", -12, -y + 3)
    smoothCB:SetScript("OnClick", function()
        CL.SetSetting("smoothBars", (this:GetChecked() == 1))
        RefreshOptionsWindow()
    end)
    f.smoothCB = smoothCB

    local speedLabel = pageGeneral:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    y = NextY()
    speedLabel:SetPoint("TOPLEFT", pageGeneral, "TOPLEFT", 14, -y)
    speedLabel:SetText("Bar speed")
    local speedStepper = CreateStepper(pageGeneral, 90)
    speedStepper:SetPoint("TOPRIGHT", pageGeneral, "TOPRIGHT", -12, -y + 1)
    speedStepper.minus:SetScript("OnClick", function()
        local v = CL.GetBarSpeed() - 1
        if v < 1 then v = 1 end
        CL.SetSetting("barSpeed", v)
        RefreshOptionsWindow()
    end)
    speedStepper.plus:SetScript("OnClick", function()
        local v = CL.GetBarSpeed() + 1
        if v > 10 then v = 10 end
        CL.SetSetting("barSpeed", v)
        RefreshOptionsWindow()
    end)
    f.speedStepper = speedStepper

    -- Advanced tab starts its own row count fresh from the top.
    -- Encounter-end timing (idle timeout) isn't exposed here - see
    -- CL.IDLE_SECONDS in Core.lua for why.
    yOffset = 60

    -- Announce
    local announceHeader = pageAdvanced:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    y = NextY()
    announceHeader:SetPoint("TOPLEFT", pageAdvanced, "TOPLEFT", 14, -y)
    announceHeader:SetText("|cffffd700Announce|r")

    local announceChanLabel = pageAdvanced:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    y = NextY()
    announceChanLabel:SetPoint("TOPLEFT", pageAdvanced, "TOPLEFT", 14, -y)
    announceChanLabel:SetText("Channel")
    local announceChanBtn = CreateSmallButton(pageAdvanced, 130, "")
    announceChanBtn:SetPoint("TOPRIGHT", pageAdvanced, "TOPRIGHT", -12, -y + 1)
    announceChanBtn:SetScript("OnClick", function()
        local cur = CL.GetSetting("announceChannel") or "auto"
        CL.SetSetting("announceChannel", CycleKey(CL.ANNOUNCE_CHANNELS, cur))
        RefreshOptionsWindow()
    end)
    f.announceChanBtn = announceChanBtn

    local announceCountLabel = pageAdvanced:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    y = NextY()
    announceCountLabel:SetPoint("TOPLEFT", pageAdvanced, "TOPLEFT", 14, -y)
    announceCountLabel:SetText("Announce top")
    local announceCountStepper = CreateStepper(pageAdvanced, 90)
    announceCountStepper:SetPoint("TOPRIGHT", pageAdvanced, "TOPRIGHT", -12, -y + 1)
    announceCountStepper.minus:SetScript("OnClick", function()
        local v = (CL.GetSetting("announceCount") or 5) - 1
        if v < 1 then v = 1 end
        CL.SetSetting("announceCount", v)
        RefreshOptionsWindow()
    end)
    announceCountStepper.plus:SetScript("OnClick", function()
        local v = (CL.GetSetting("announceCount") or 5) + 1
        if v > 10 then v = 10 end
        CL.SetSetting("announceCount", v)
        RefreshOptionsWindow()
    end)
    f.announceCountStepper = announceCountStepper

    local announcePullsLabel = pageAdvanced:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    y = NextY()
    announcePullsLabel:SetPoint("TOPLEFT", pageAdvanced, "TOPLEFT", 14, -y)
    announcePullsLabel:SetText("Announce pulls (boss only)")
    local announcePullsCB = CreateFrame("CheckButton", "CombatLedgerAnnouncePullsCB", pageAdvanced, "UICheckButtonTemplate")
    announcePullsCB:SetWidth(20)
    announcePullsCB:SetHeight(20)
    announcePullsCB:SetPoint("TOPRIGHT", pageAdvanced, "TOPRIGHT", -12, -y + 3)
    announcePullsCB:SetScript("OnClick", function()
        CL.SetSetting("announcePulls", (this:GetChecked() == 1))
    end)
    f.announcePullsCB = announcePullsCB

    local testLabel = pageAdvanced:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    y = NextY()
    testLabel:SetPoint("TOPLEFT", pageAdvanced, "TOPLEFT", 14, -y)
    testLabel:SetText("Test mode (fill with dummy data)")
    local testCB = CreateFrame("CheckButton", "CombatLedgerTestModeCB", pageAdvanced, "UICheckButtonTemplate")
    testCB:SetWidth(20)
    testCB:SetHeight(20)
    testCB:SetPoint("TOPRIGHT", pageAdvanced, "TOPRIGHT", -12, -y + 3)
    testCB:SetScript("OnClick", function()
        CL.testMode = (this:GetChecked() == 1)
        CL.FireAppearanceChanged()
    end)
    f.testCB = testCB

    -- Auto-resets (or offers to reset) the Overall segment the instant
    -- you go from solo to grouped (see Events.lua's
    -- PARTY_MEMBERS_CHANGED/RAID_ROSTER_UPDATE handler) - handy for
    -- keeping Overall meaning "this raid" instead of carrying over
    -- whatever solo grinding happened beforehand. Doesn't touch Current
    -- Fight or saved History, same as the R (Reset) button. Two
    -- checkboxes acting as one 3-way choice (off/always/ask) instead of
    -- a dropdown - checking one unchecks the other; unchecking the
    -- active one goes back to off.
    local clearAlwaysLabel = pageAdvanced:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    y = NextY()
    clearAlwaysLabel:SetPoint("TOPLEFT", pageAdvanced, "TOPLEFT", 14, -y)
    clearAlwaysLabel:SetText("Always clear on join party")
    local clearOnJoinAlwaysCB = CreateFrame("CheckButton", "CombatLedgerClearOnJoinAlwaysCB", pageAdvanced, "UICheckButtonTemplate")
    clearOnJoinAlwaysCB:SetWidth(20)
    clearOnJoinAlwaysCB:SetHeight(20)
    clearOnJoinAlwaysCB:SetPoint("TOPRIGHT", pageAdvanced, "TOPRIGHT", -12, -y + 3)
    clearOnJoinAlwaysCB:SetScript("OnClick", function()
        if this:GetChecked() == 1 then
            CL.SetSetting("clearOnJoinPartyMode", "always")
            f.clearOnJoinAskCB:SetChecked(false)
        else
            CL.SetSetting("clearOnJoinPartyMode", "off")
        end
    end)
    f.clearOnJoinAlwaysCB = clearOnJoinAlwaysCB

    local clearAskLabel = pageAdvanced:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    y = NextY()
    clearAskLabel:SetPoint("TOPLEFT", pageAdvanced, "TOPLEFT", 14, -y)
    clearAskLabel:SetText("Ask before clearing")
    local clearOnJoinAskCB = CreateFrame("CheckButton", "CombatLedgerClearOnJoinAskCB", pageAdvanced, "UICheckButtonTemplate")
    clearOnJoinAskCB:SetWidth(20)
    clearOnJoinAskCB:SetHeight(20)
    clearOnJoinAskCB:SetPoint("TOPRIGHT", pageAdvanced, "TOPRIGHT", -12, -y + 3)
    clearOnJoinAskCB:SetScript("OnClick", function()
        if this:GetChecked() == 1 then
            CL.SetSetting("clearOnJoinPartyMode", "ask")
            f.clearOnJoinAlwaysCB:SetChecked(false)
        else
            CL.SetSetting("clearOnJoinPartyMode", "off")
        end
    end)
    f.clearOnJoinAskCB = clearOnJoinAskCB

    -- Windows - "main" (this addon's original single window) always
    -- exists and isn't listed here; extra windows are what "+ New
    -- Window" creates, each an independent mode/segment/size/position
    -- (see UI_MainWindow.lua's instance factory) so e.g. Healing can sit
    -- in one window while Damage sits in another. Fixed-size row pool
    -- (MAX_WINDOW_ROWS) like the rest of this window's fixed layout,
    -- not a scroll list - refreshed from CL.UI.GetWindowList() below.
    AddDivider(pageAdvanced)
    local windowsHeader = pageAdvanced:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    y = NextY()
    windowsHeader:SetPoint("TOPLEFT", pageAdvanced, "TOPLEFT", 14, -y)
    windowsHeader:SetText("|cffffd700Windows|r")

    local newWindowBtn = CreateSmallButton(pageAdvanced, WINDOW_WIDTH - 28, "+ New Window")
    y = NextY()
    newWindowBtn:SetPoint("TOPLEFT", pageAdvanced, "TOPLEFT", 14, -y)
    newWindowBtn:SetScript("OnClick", function()
        if CL.UI and CL.UI.CreateExtraWindow then
            CL.UI.CreateExtraWindow()
            RefreshOptionsWindow()
        end
    end)
    f.newWindowBtn = newWindowBtn

    -- Each row is three lines now: name + close button on top, this
    -- window's own auto-show/auto-hide/grouped-only toggles below that,
    -- then a "Mirror Main" button (extra windows only - a one-time copy
    -- of Main's current size/position, not a persistent link) - takes
    -- three NextY() slots' worth of vertical space per row instead of
    -- one (see the matching WINDOW_HEIGHT bump).
    -- Captured so RefreshOptionsWindow can reflow resetPosBtn to sit
    -- right after however many windows actually exist right now,
    -- instead of always leaving room for the full MAX_WINDOW_ROWS - most
    -- people only run 1-2 extra windows, so the fixed layout used to
    -- leave a big dead gap between the last real row and everything
    -- below it.
    local windowRowsStartY = yOffset
    local ROW_SLOT_HEIGHT = 3 * ROW_HEIGHT
    f.windowRowsStartY = windowRowsStartY
    f.rowSlotHeight = ROW_SLOT_HEIGHT

    f.windowRows = {}
    local wi
    for wi = 1, MAX_WINDOW_ROWS do
        y = NextY()
        NextY()
        NextY()
        local row = CreateFrame("Frame", nil, pageAdvanced)
        row:SetPoint("TOPLEFT", pageAdvanced, "TOPLEFT", 14, -y)
        row:SetPoint("TOPRIGHT", pageAdvanced, "TOPRIGHT", -12, -y)
        row:SetHeight(3 * ROW_HEIGHT - 4)

        local rowLabel = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        rowLabel:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
        rowLabel:SetPoint("TOPRIGHT", row, "TOPRIGHT", -20, 0)
        rowLabel:SetJustifyH("LEFT")
        row.rowLabel = rowLabel

        local rowCloseBtn = CreateSmallButton(row, 16, "X")
        rowCloseBtn:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)
        row.rowCloseBtn = rowCloseBtn

        -- Compact checkbox+label pairs, left to right - "Show" (auto-
        -- show on combat start), "Hide" (auto-hide out of combat),
        -- "Grouped" (only show while in a party/raid). The labels alone
        -- don't say enough at this size, so each gets a hover tooltip
        -- spelling out exactly what it does.
        local function CreateRowToggle(labelText, tooltip, xOffset)
            local cb = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
            cb:SetWidth(16)
            cb:SetHeight(16)
            cb:SetPoint("TOPLEFT", row, "TOPLEFT", xOffset, -20)
            local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            label:SetPoint("LEFT", cb, "RIGHT", 2, 0)
            label:SetText(labelText)
            cb:SetScript("OnEnter", function()
                GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
                GameTooltip:SetText(tooltip, nil, nil, nil, nil, true)
                GameTooltip:Show()
            end)
            cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
            return cb
        end
        row.showCB = CreateRowToggle("Auto-show", "Auto-show this window the moment combat starts.", 0)
        row.hideCB = CreateRowToggle("Auto-hide", "Auto-hide this window the moment combat ends.", 92)
        row.groupCB = CreateRowToggle("Grouped only", "Only ever auto-show this window while you're in a party or raid - hides it immediately if you leave group, even mid-combat.", 186)

        local mirrorBtn = CreateSmallButton(row, WINDOW_WIDTH - 26, "Mirror Main (size/position)")
        mirrorBtn:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -40)
        row.mirrorBtn = mirrorBtn

        f.windowRows[wi] = row
    end

    y = NextY() + 6
    local resetPosBtn = CreateSmallButton(pageAdvanced, WINDOW_WIDTH - 28, "Reset Window Positions")
    resetPosBtn:SetPoint("TOPLEFT", pageAdvanced, "TOPLEFT", 14, -y)
    resetPosBtn:SetScript("OnClick", function()
        CombatLedgerDB.layout = {}
        CL.Print("Window positions reset - reopen each window (or /reload) to see it at its default spot.")
    end)
    f.resetPosBtn = resetPosBtn

    ShowTab("general")

    if pfUI and pfUI.api then
        pcall(function()
            pfUI.api.CreateBackdrop(f)
            pfUI.api.CreateBackdropShadow(f)
            pfUI.api.SkinCloseButton(closeBtn)
            pfUI.api.SkinCheckbox(lockCB)
            pfUI.api.SkinCheckbox(minimapCB)
            pfUI.api.SkinCheckbox(hideBorderCB)
            pfUI.api.SkinCheckbox(classIconCB)
            pfUI.api.SkinCheckbox(highlightSelfCB)
            pfUI.api.SkinCheckbox(barBorderCB)
            pfUI.api.SkinCheckbox(classColorCB)
            pfUI.api.SkinCheckbox(smoothCB)
            pfUI.api.SkinCheckbox(testCB)
            pfUI.api.SkinCheckbox(clearOnJoinAlwaysCB)
            pfUI.api.SkinCheckbox(clearOnJoinAskCB)
            pfUI.api.SkinCheckbox(announcePullsCB)
            if matchPfuiCB then pfUI.api.SkinCheckbox(matchPfuiCB) end
            pfUI.api.SkinButton(textureBtn)
            pfUI.api.SkinButton(fontBtn)
            pfUI.api.SkinButton(numberFmtBtn)
            pfUI.api.SkinButton(resetPosBtn)
            pfUI.api.SkinButton(newWindowBtn)
            pfUI.api.SkinButton(tabGeneralBtn)
            pfUI.api.SkinButton(tabAdvancedBtn)
            local wi
            for wi = 1, table.getn(f.windowRows) do
                pfUI.api.SkinButton(f.windowRows[wi].rowCloseBtn)
                pfUI.api.SkinButton(f.windowRows[wi].mirrorBtn)
                pfUI.api.SkinCheckbox(f.windowRows[wi].showCB)
                pfUI.api.SkinCheckbox(f.windowRows[wi].hideCB)
                pfUI.api.SkinCheckbox(f.windowRows[wi].groupCB)
            end
            pfUI.api.SkinButton(fontSizeStepper.minus)
            pfUI.api.SkinButton(fontSizeStepper.plus)
            pfUI.api.SkinButton(barHeightStepper.minus)
            pfUI.api.SkinButton(barHeightStepper.plus)
            pfUI.api.SkinButton(opacityStepper.minus)
            pfUI.api.SkinButton(opacityStepper.plus)
            pfUI.api.SkinButton(speedStepper.minus)
            pfUI.api.SkinButton(speedStepper.plus)
            pfUI.api.SkinButton(announceChanBtn)
            pfUI.api.SkinButton(announceCountStepper.minus)
            pfUI.api.SkinButton(announceCountStepper.plus)
        end)
        f:SetBackdropBorderColor(themeR, themeG, themeB, 1)
    end

    CL.ApplyFontToTree(f)

    window = f
    return f
end

-- Walking the whole window is cheap and guarantees every label/title/
-- checkbox/stepper in this window picks up a font change, without
-- having to hand-instrument each one - see CL.ApplyFontToTree.
CL.OnAppearanceChanged(function()
    if window then CL.ApplyFontToTree(window) end
end)

RefreshOptionsWindow = function()
    if not window then return end

    window.lockCB:SetChecked(CL.GetSetting("lockWindow"))
    window.minimapCB:SetChecked(CL.GetSetting("showMinimapButton") ~= false)
    if window.matchPfuiCB then
        window.matchPfuiCB:SetChecked(CL.IsMatchPfui())
    end

    -- " |cff999999v|r" suffix marks these as dropdowns (click opens a
    -- list via CL.ShowDropdown) rather than the cycle-on-click buttons
    -- they used to be, which wasn't obvious from a plain value label.
    window.textureBtn.label:SetText(LabelForKey(CL.GetAvailableBarTextures(), CL.GetSetting("barTexture") or "flat") .. " |cff999999v|r")
    window.hideBorderCB:SetChecked(CL.GetSetting("hideBorder"))
    window.classIconCB:SetChecked(CL.GetSetting("showClassIcon"))
    window.highlightSelfCB:SetChecked(CL.GetSetting("highlightSelf"))
    do
        local sc = CL.GetSetting("highlightSelfColor")
        window.highlightSelfSwatch:SetBackdropColor(sc[1], sc[2], sc[3], 1)
    end
    window.barBorderCB:SetChecked(CL.GetSetting("barBorderEnabled"))
    do
        local bc = CL.GetSetting("barBorderColor")
        window.barBorderSwatch:SetBackdropColor(bc[1], bc[2], bc[3], 1)
    end
    window.classColorCB:SetChecked(CL.GetSetting("classColorMenus"))
    window.fontBtn.label:SetText(LabelForKey(CL.FONTS, CL.GetSetting("fontKey") or "friz") .. " |cff999999v|r")
    window.fontSizeStepper.value:SetText(tostring(CL.GetSetting("fontSize") or 10))
    local barHeight = CL.GetSetting("barHeight")
    window.barHeightStepper.value:SetText(barHeight and tostring(barHeight) or "Default")
    window.numberFmtBtn.label:SetText(LabelForKey(CL.NUMBER_FORMATS, CL.GetSetting("numberFormat") or "abbreviated") .. " |cff999999v|r")
    window.opacityStepper.value:SetText((CL.GetSetting("windowOpacityPct") or 85) .. "%")

    local matchOn = CL.IsMatchPfui()
    SetControlEnabled(window.textureBtn, not matchOn)
    SetControlEnabled(window.fontBtn, not matchOn)
    SetControlEnabled(window.fontSizeStepper, not matchOn)
    SetControlEnabled(window.opacityStepper, not matchOn)

    window.smoothCB:SetChecked(CL.IsSmoothBars())
    window.speedStepper.value:SetText(tostring(CL.GetBarSpeed()))
    SetControlEnabled(window.speedStepper, CL.IsSmoothBars())

    window.announceChanBtn.label:SetText(LabelForKey(CL.ANNOUNCE_CHANNELS, CL.GetSetting("announceChannel") or "auto"))
    window.announceCountStepper.value:SetText(tostring(CL.GetSetting("announceCount") or 5))
    window.announcePullsCB:SetChecked(CL.GetSetting("announcePulls") ~= false)

    window.testCB:SetChecked(CL.testMode)
    local clearMode = CL.GetSetting("clearOnJoinPartyMode")
    window.clearOnJoinAlwaysCB:SetChecked(clearMode == "always")
    window.clearOnJoinAskCB:SetChecked(clearMode == "ask")

    if window.windowRows then
        local list = (CL.UI and CL.UI.GetWindowList and CL.UI.GetWindowList()) or {}
        local wi
        for wi = 1, table.getn(window.windowRows) do
            local row = window.windowRows[wi]
            local entry = list[wi]
            if entry then
                local id = entry.id
                row.rowLabel:SetText(entry.label .. (entry.closable and "" or " |cff888888(Main)|r"))
                if entry.closable then
                    row.rowCloseBtn:Show()
                    row.rowCloseBtn:SetScript("OnClick", function()
                        if CL.UI and CL.UI.CloseExtraWindow then
                            CL.UI.CloseExtraWindow(id)
                            RefreshOptionsWindow()
                        end
                    end)
                    row.mirrorBtn:Show()
                    row.mirrorBtn:SetScript("OnClick", function()
                        if CL.UI and CL.UI.MirrorMainLayout then
                            CL.UI.MirrorMainLayout(id)
                        end
                    end)
                else
                    row.rowCloseBtn:Hide()
                    row.mirrorBtn:Hide()
                end

                row.showCB:SetChecked(CL.GetWindowOption(id, "autoShowInCombat", true))
                row.showCB:SetScript("OnClick", function()
                    CL.SetWindowOption(id, "autoShowInCombat", (this:GetChecked() == 1))
                end)

                row.hideCB:SetChecked(CL.GetWindowOption(id, "autoHideOutOfCombat", false))
                row.hideCB:SetScript("OnClick", function()
                    local checked = (this:GetChecked() == 1)
                    CL.SetWindowOption(id, "autoHideOutOfCombat", checked)
                    -- Take effect right away rather than waiting for the
                    -- next combat transition, which might not come for a
                    -- while (or ever, if already out of combat) - checking
                    -- it hides now if out of combat; unchecking it
                    -- un-hides now UNLESS Grouped-only is also on and
                    -- you're not grouped, in which case that rule still
                    -- says this window shouldn't be up (IsSuppressedNow
                    -- checks both rules together, not just this one).
                    if CL.UI and not UnitAffectingCombat("player") then
                        if checked and CL.UI.ApplyAutoHide then
                            CL.UI.ApplyAutoHide()
                        elseif not checked and CL.UI.ShowWindowById and CL.UI.IsSuppressedNow
                            and not CL.UI.IsSuppressedNow(id) then
                            CL.UI.ShowWindowById(id)
                        end
                    end
                end)

                row.groupCB:SetChecked(CL.GetWindowOption(id, "onlyShowGrouped", false))
                row.groupCB:SetScript("OnClick", function()
                    local checked = (this:GetChecked() == 1)
                    CL.SetWindowOption(id, "onlyShowGrouped", checked)
                    if CL.UI then
                        if checked and CL.UI.ReconcileGroupVisibility then
                            CL.UI.ReconcileGroupVisibility()
                        elseif not checked and CL.UI.ShowWindowById and CL.UI.IsSuppressedNow
                            and not CL.UI.IsSuppressedNow(id) then
                            -- Same reasoning as Auto-hide above - lifting
                            -- this restriction should reveal the window
                            -- now UNLESS Auto-hide is also on and you're
                            -- out of combat, which still says it should
                            -- stay hidden.
                            CL.UI.ShowWindowById(id)
                        end
                    end
                end)

                row:Show()
            else
                row:Hide()
            end
        end

        -- Reflow resetPosBtn to sit right after however many rows are
        -- actually populated (table.getn(list)), not the full
        -- MAX_WINDOW_ROWS worth of reserved space.
        if window.resetPosBtn and window.windowRowsStartY and window.rowSlotHeight then
            local n = table.getn(list)
            window.resetPosBtn:ClearAllPoints()
            window.resetPosBtn:SetPoint("TOPLEFT", window, "TOPLEFT", 14,
                -(window.windowRowsStartY + n * window.rowSlotHeight + 6))
        end
    end
end

function OPT.Toggle()
    if not window then CreateWindow() end
    if window:IsShown() then
        window:Hide()
    else
        RefreshOptionsWindow()
        window:Show()
    end
end

function OPT.Show()
    if not window then CreateWindow() end
    RefreshOptionsWindow()
    window:Show()
end

--------------------------------------------------------------------------
-- Minimap button - same draggable-icon pattern as LootLedger's own
-- CreateMinimapButton. Left-click toggles the main meter; right-click
-- opens Options.
--------------------------------------------------------------------------

local function CreateMinimapButton()
    local btn = CreateFrame("Button", "CombatLedgerMinimapButton", Minimap)
    btn:SetWidth(31)
    btn:SetHeight(31)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")
    btn:SetMovable(true)

    local overlay = btn:CreateTexture(nil, "OVERLAY")
    overlay:SetWidth(53)
    overlay:SetHeight(53)
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetPoint("TOPLEFT", 0, 0)

    local icon = btn:CreateTexture(nil, "BACKGROUND")
    icon:SetWidth(20)
    icon:SetHeight(20)
    -- Was Ability_DualWield - collided with this server's preinstalled
    -- BG Finder addon using the exact same icon, making the two
    -- indistinguishable on the minimap. A book fits "Ledger" anyway.
    icon:SetTexture("Interface\\Icons\\INV_Misc_Book_09")
    icon:SetPoint("TOPLEFT", 7, -6)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local highlight = btn:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetWidth(20)
    highlight:SetHeight(20)
    highlight:SetPoint("TOPLEFT", 7, -6)
    highlight:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    highlight:SetBlendMode("ADD")

    local function UpdatePosition(angle)
        btn:ClearAllPoints()
        btn:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * 80, math.sin(angle) * 80)
    end
    btn.UpdatePosition = UpdatePosition

    -- This client restores the real CombatLedgerDB from disk AFTER this
    -- file finishes executing (same timing quirk as CL.ApplyLayout - see
    -- Core.lua), so a saved minimapAngle read right here would always
    -- be nil - just place it at the default for now, OPT.RefreshMinimap
    -- Position (called from Events.lua's first PLAYER_ENTERING_WORLD)
    -- re-reads it once the real data actually exists.
    UpdatePosition(3.93) -- ~225 deg, bottom-left

    btn:SetScript("OnDragStart", function()
        this:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local px, py = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            px, py = px / scale, py / scale
            local angle = math.atan2(py - my, px - mx)
            CombatLedgerDB.minimapAngle = angle
            UpdatePosition(angle)
        end)
    end)
    btn:SetScript("OnDragStop", function()
        this:SetScript("OnUpdate", nil)
    end)

    btn:SetScript("OnClick", function()
        if arg1 == "RightButton" then
            OPT.Toggle()
        elseif CL.UI then
            CL.UI.Toggle()
        end
    end)

    btn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_LEFT")
        local r, g, b, hex = CL.GetThemeColor()
        GameTooltip:SetText("|cff" .. hex .. "CombatLedger|r")
        GameTooltip:AddLine("Click to toggle the meter", 1, 1, 1)
        GameTooltip:AddLine("Right-click for Options", 1, 1, 1)
        GameTooltip:AddLine("Drag to move this button", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    return btn
end

function OPT.RefreshMinimapPosition()
    if not minimapButton then return end
    local angle = (CombatLedgerDB and CombatLedgerDB.minimapAngle) or 3.93
    minimapButton.UpdatePosition(angle)
end

function OPT.RefreshMinimapVisibility()
    if not minimapButton then return end
    if CL.GetSetting("showMinimapButton") == false then
        minimapButton:Hide()
    else
        minimapButton:Show()
    end
end

minimapButton = CreateMinimapButton()
