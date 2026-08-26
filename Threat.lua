--[[
    Threat - live per-target threat.

    Primary path: this server answers a plain Blizzard addon message
    ("TWT_UDTSv4") with a reply over CHAT_MSG_ADDON (prefix "TWTv4=")
    containing group members' current threat against your target. This
    is the same request/reply protocol TWThreat uses; it needs no addon
    handshake or registration message. The request limit must stay in
    TWThreat's supported range: TWThreat exposes 5-11 visible bars and
    requests visibleBars - 1, so the largest valid request is 10.

    Fallback path: EstimateThreat() below computes threat locally from
    CombatLedger's own already-tracked damage/healing data, the same
    approach GreedMeter's Threat.lua uses (confirmed via its own source -
    "Uses the server threat addon API when available; otherwise
    estimates from meter data"). Runs whenever a poll happens but no
    real reply has landed recently, so the real API (on the rare group
    that happens to satisfy it) always wins when available.

    Threat has no "Overall" or "History" - it's always a live snapshot
    of whatever the server just reported (or was last estimated) for the
    current target, reset the moment the target (or combat state)
    changes. UI_MainWindow.lua's Threat mode reads CL.Threat.GetSnapshot()
    directly instead of going through the Current/Overall/segment
    machinery every other mode uses.
]]

local CL = CombatLedger

local REQUEST_PREFIX = "TWT_UDTSv4"
local REPLY_PREFIX = "TWTv4="
local POLL_INTERVAL = 0.5 -- matches TWThreat's own polling cadence
-- TWThreat caps visibleBars at 11 and sends visibleBars - 1. Values above
-- 10 can be silently ignored by the server, leaving only local estimates.
local REQUEST_LIMIT = 10

-- How long to wait after a poll with no real reply before estimating -
-- generous enough that a real reply arriving just slightly late (server
-- hiccup, not "this group doesn't get real replies at all") still wins;
-- see EstimateThreat below and its call site in the poll loop.
local ESTIMATE_GRACE = 2

-- [guid] = { name, threat, perc, melee, tank } - declared here (not
-- down by the roster-scan code below, where these originally lived)
-- since EstimateThreat, defined next, assigns to all three and Lua's
-- single-pass compiler needs the local declaration to already be in
-- scope above any reference to it - a local declared later resolves as
-- a nonexistent global instead (confirmed the hard way: "attempt to
-- perform arithmetic on global 'lastUpdate' (a nil value)").
local current = {}
local tankGuid = nil
local lastUpdate = 0

-- ============================================================
-- Local threat estimation (fallback when no real server reply arrives -
-- see this file's header comment for why that's needed at all). This is
-- deliberately owned entirely by Threat.lua: it reads Aggregator's
-- already-existing per-target buckets, but never writes to them, so no
-- Damage/Healing/History mode is changed by the estimator.
--
-- Nampower gives us target GUIDs for every damage event and exposes the
-- spell DBC plus SPELL_GO. That is enough to keep the fallback scoped to
-- the selected enemy and to account for explicit THREAT/THREAT_ALL spell
-- effects (Sunder-style zero-damage threat) without guessing from combat
-- text. It is still an estimate -- only a TWTv4 server reply is truth.
-- ============================================================

-- Class baseline threat-generation modifiers (relative, not absolute)
local CLASS_THREAT_MOD = {
    WARRIOR = 1.15,
    PALADIN = 1.10,
    DRUID   = 1.05,
    ROGUE   = 0.71,
    HUNTER  = 0.65,
    MAGE    = 0.70,
    WARLOCK = 0.72,
    PRIEST  = 0.55,
    SHAMAN  = 0.75,
}

-- Damage abilities with higher-than-normal threat coefficients (1.12
-- approximations) - applied to that spell's damage total already
-- tracked in Aggregator's per-spell breakdown.
local SPELL_DAMAGE_THREAT_MULT = {
    ["Mind Blast"] = 2.00,
    ["Searing Pain"] = 2.00,
    ["Shield Slam"] = 1.50,
    ["Revenge"] = 2.00,
    ["Maul"] = 1.75,
    ["Heroic Strike"] = 1.25,
    ["Cleave"] = 1.15,
    ["Thunder Clap"] = 1.75,
    ["Mocking Blow"] = 2.50,
    ["Holy Shield"] = 1.30,
    ["Lacerate"] = 1.30,
    ["Devastate"] = 1.50,
}

-- Nampower mirrors the vanilla SpellEffect and SpellAttr enums. These
-- constants are intentionally local to Threat mode; the normal meter
-- pipeline has no reason to know about threat-only DBC details.
local SPELL_EFFECT_THREAT = 63
local SPELL_EFFECT_THREAT_ALL = 91
local SPELL_ATTR_EX_NO_THREAT = 1024 -- 0x00000400

local ZERO_GUID = "0x0000000000000000"

local function ValidGuid(guid)
    return guid and guid ~= "" and guid ~= ZERO_GUID and guid ~= "0x000000000"
end

local function SpellField(spellId, field)
    if not spellId or not GetSpellRecField then return nil end
    local ok, value = pcall(GetSpellRecField, spellId, field, 1)
    if ok then return value end
    return nil
end

local function SpellHasInitialDamageThreat(spellId)
    if not spellId or spellId < 0 then return true end
    local attributesEx = tonumber(SpellField(spellId, "attributesEx")) or 0
    if CL.HasBit and CL.HasBit(attributesEx, SPELL_ATTR_EX_NO_THREAT) then return false end
    return true
end

local function SpellDamageThreatMult(spell, spellId)
    if not SpellHasInitialDamageThreat(spellId) then return 0 end
    if not spell or spell == "" then return 1.0 end
    local m = SPELL_DAMAGE_THREAT_MULT[spell]
    if m then return m end
    local key, mult
    for key, mult in pairs(SPELL_DAMAGE_THREAT_MULT) do
        if string.find(spell, key, 1, true) then
            return mult
        end
    end
    return 1.0
end

-- Threat that does not have a damage number (SPELL_EFFECT_THREAT and
-- SPELL_EFFECT_THREAT_ALL) is kept here, completely separate from the
-- Aggregator used by every other meter mode:
--   [enemyGuid][rosterGuid] = threat delta
local explicitThreat = {}
local deadEnemies = {}
local healingSeenTotals = {}

local function AttributedGuid(guid)
    if CL.GuidCache and CL.GuidCache.GetOwner then
        local owner = CL.GuidCache.GetOwner(guid)
        if owner then return owner end
    end
    return guid
end

local function IsTrackedGuid(guid)
    return guid and CL.GuidCache and CL.GuidCache.IsTracked and CL.GuidCache.IsTracked(AttributedGuid(guid))
end

local function AddExplicitThreat(enemyGuid, actorGuid, amount)
    enemyGuid = AttributedGuid(enemyGuid)
    actorGuid = AttributedGuid(actorGuid)
    amount = tonumber(amount) or 0
    if not ValidGuid(enemyGuid) or not IsTrackedGuid(actorGuid) or amount == 0 then return end
    local byActor = explicitThreat[enemyGuid]
    if not byActor then
        byActor = {}
        explicitThreat[enemyGuid] = byActor
    end
    byActor[actorGuid] = math.max(0, (byActor[actorGuid] or 0) + amount)
end

-- Returns the target-specific and all-engaged-enemy threat encoded in a
-- spell's DBC effects. EffectBasePoints is stored as value-1 in vanilla.
local function ExplicitSpellThreat(spellId)
    local effects = SpellField(spellId, "effect")
    local basePoints = SpellField(spellId, "effectBasePoints")
    if type(effects) ~= "table" or type(basePoints) ~= "table" then return 0, 0 end
    local targetThreat, allThreat = 0, 0
    local i
    for i = 1, 3 do
        local effect = tonumber(effects[i])
        local amount = (tonumber(basePoints[i]) or -1) + 1
        if effect == SPELL_EFFECT_THREAT then
            targetThreat = targetThreat + amount
        elseif effect == SPELL_EFFECT_THREAT_ALL then
            allThreat = allThreat + amount
        end
    end
    return targetThreat, allThreat
end

local function EnemyIsStillActive(guid)
    if not ValidGuid(guid) or deadEnemies[guid] then return false end
    -- A GUID may fall out of the client's live object map while still
    -- engaged. Only exclude it when the API positively says it is dead.
    if UnitIsDead then
        local ok, isDead = pcall(UnitIsDead, guid)
        if ok and isDead then return false end
    end
    return true
end

local function CollectActiveEnemies(enc, includeGuid)
    local set = {}
    local count = 0
    if enc and enc.units then
        local _, u
        for _, u in pairs(enc.units) do
            local targets = u.damageDone and u.damageDone.targets
            if targets then
                local targetGuid
                for targetGuid in pairs(targets) do
                    if not set[targetGuid] and not IsTrackedGuid(targetGuid) and EnemyIsStillActive(targetGuid) then
                        set[targetGuid] = true
                        count = count + 1
                    end
                end
            end
        end
    end
    if ValidGuid(includeGuid) and not set[includeGuid] and EnemyIsStillActive(includeGuid) then
        set[includeGuid] = true
        count = count + 1
    end
    return set, math.max(1, count)
end

-- Reconcile only healing that has not yet been assigned. This preserves
-- the enemy set that was active when the healing happened instead of
-- repeatedly dividing the encounter's entire healing total by whatever
-- number of enemies happen to remain alive now.
local function ReconcileHealingThreat(enc, enemies, enemyCount)
    if not enc or not enc.units then return end
    local guid, u
    for guid, u in pairs(enc.units) do
        local total = u.healingDone and (u.healingDone.total or 0) or 0
        local seen = healingSeenTotals[guid] or 0
        if total < seen then seen = 0 end -- defensive encounter-reset guard
        local delta = total - seen
        if delta > 0 then
            local perEnemy = (delta * 0.5) / enemyCount
            local enemyGuid
            for enemyGuid in pairs(enemies) do
                AddExplicitThreat(enemyGuid, guid, perEnemy)
            end
        end
        healingSeenTotals[guid] = total
    end
end

-- Compute one player's estimate against one enemy. Damage is read only
-- from damageDone.targets[targetGuid], never from encounter-wide totals.
-- Healing threat is shared across the enemies still active in this pull,
-- matching vanilla's multi-mob healing-threat behavior as closely as the
-- client-visible event stream permits.
local function EstimateUnitThreat(u, guid, targetGuid)
    if not u then return 0 end
    local mod = 1.0
    if u.classToken and CLASS_THREAT_MOD[u.classToken] then
        mod = CLASS_THREAT_MOD[u.classToken]
    end

    local targetBucket = u.damageDone and u.damageDone.targets and u.damageDone.targets[targetGuid]
    local dmgThreat = 0
    if targetBucket and targetBucket.spells then
        local spellId, entry
        for spellId, entry in pairs(targetBucket.spells) do
            dmgThreat = dmgThreat + (entry.total or 0) * SpellDamageThreatMult(entry.name, spellId)
        end
    end
    if targetBucket then
        if targetBucket.melee then dmgThreat = dmgThreat + (targetBucket.melee.total or 0) end
        if targetBucket.offhand then dmgThreat = dmgThreat + (targetBucket.offhand.total or 0) end
        if targetBucket.petMelee then dmgThreat = dmgThreat + (targetBucket.petMelee.total or 0) end
        if targetBucket.petOffhand then dmgThreat = dmgThreat + (targetBucket.petOffhand.total or 0) end
    end

    local extra = explicitThreat[targetGuid] and explicitThreat[targetGuid][guid] or 0
    return (dmgThreat + extra) * mod, targetBucket
end

-- Populates current/tankGuid from CombatLedger's own live encounter
-- data (CL.Aggregator.GetCurrent().units) instead of a server reply.
-- Same output shape HandleThreatPacket produces, so the UI needs no
-- changes to consume either source.
local function EstimateThreat(targetGuid)
    if not ValidGuid(targetGuid) then return false end
    local enc = CL.Aggregator and CL.Aggregator.GetCurrent and CL.Aggregator.GetCurrent()
    if not enc or not enc.units then return false end

    local activeEnemies, activeEnemyCount = CollectActiveEnemies(enc, targetGuid)
    ReconcileHealingThreat(enc, activeEnemies, activeEnemyCount)
    local newCurrent = {}
    local maxThreat = 0
    local guid, u
    for guid, u in pairs(enc.units) do
        local threat, targetBucket = EstimateUnitThreat(u, guid, targetGuid)
        if threat > 0 then
            local melee = targetBucket and (
                (targetBucket.melee and (targetBucket.melee.total or 0) > 0) or
                (targetBucket.offhand and (targetBucket.offhand.total or 0) > 0) or
                (targetBucket.petMelee and (targetBucket.petMelee.total or 0) > 0) or
                (targetBucket.petOffhand and (targetBucket.petOffhand.total or 0) > 0)) or false
            newCurrent[guid] = { name = u.name or guid, threat = threat, estimated = true, melee = melee }
            if threat > maxThreat then maxThreat = threat end
        end
    end

    if maxThreat <= 0 then return false end

    local newTank = nil
    local maxSeen = 0
    for guid, entry in pairs(newCurrent) do
        entry.perc = math.floor((entry.threat / maxThreat) * 100 + 0.5)
        entry.tank = false
        if entry.threat > maxSeen then
            maxSeen = entry.threat
            newTank = guid
        end
    end
    if newTank then newCurrent[newTank].tank = true end

    current = newCurrent
    tankGuid = newTank

    if CL.debug then
        CL.LogLine("[Threat] estimated target=" .. tostring(targetGuid) .. " " .. CL.TableCount(newCurrent) .. " players (no real reply for " ..
            string.format("%.1f", GetTime() - lastUpdate) .. "s)")
    end

    if CL.UI and CL.UI.RefreshMode then CL.UI.RefreshMode("threat") end
    return true
end

-- [name] = guid, from a party/raid roster scan (SuperWoW's UnitExists
-- returns a real GUID as a third value - see GuidCache.lua for the same
-- trick) - threat packets only ever name party/raid members, so this is
-- always resolvable as long as the roster scan has run recently.
local nameToGuid = {}

-- Set the moment the target changes, cleared the moment a fresh reply
-- lands. While set, the OLD target's bars are left showing rather than
-- snap-clearing to empty and popping back in half a second later - a
-- clean swap in place reads a lot better than a flash-to-blank. Only
-- if nothing comes back within STALE_TARGET_TIMEOUT do we give up and
-- actually clear, so bars for a target that stopped replying (dead,
-- out of range) don't linger forever.
local pendingTargetSince = nil
local STALE_TARGET_TIMEOUT = 2

local function AddRosterName(unit)
    local ok, exists, guid = pcall(UnitExists, unit)
    if ok and exists and guid then
        local name = UnitName(unit)
        if name then nameToGuid[name] = guid end
    end
end

local function RefreshRosterNames()
    nameToGuid = {}
    AddRosterName("player")
    if GetNumRaidMembers and GetNumRaidMembers() > 0 then
        local i
        for i = 1, 40 do
            AddRosterName("raid" .. i)
        end
    elseif GetNumPartyMembers and GetNumPartyMembers() > 0 then
        local i
        for i = 1, 4 do
            AddRosterName("party" .. i)
        end
    end
end

-- Matches TWThreat's own channel selection: 'PARTY' is the
-- unconditional fallback, sent even while solo. The server intercepts
-- by the "TWT_UDTSv4" addon-message prefix itself, not real
-- party-channel membership, so there's no "not grouped" case where
-- this should return nil.
local function GroupChannel()
    if GetNumRaidMembers and GetNumRaidMembers() > 0 then return "RAID" end
    return "PARTY"
end

-- Manual split matching TWThreat's own __explode - avoids a gmatch/
-- gfind dependency either way.
local function SplitString(str, delimiter)
    local result = {}
    local from = 1
    local delimFrom, delimTo = string.find(str, delimiter, from, true)
    while delimFrom do
        table.insert(result, string.sub(str, from, delimFrom - 1))
        from = delimTo + 1
        delimFrom, delimTo = string.find(str, delimiter, from, true)
    end
    table.insert(result, string.sub(str, from))
    return result
end

-- body: "name:isTank:threat:perc:isMelee;name2:...;..."
local function HandleThreatPacket(body)
    if CL.debug then CL.LogLine("[Threat] packet body: " .. tostring(body)) end

    local newCurrent = {}
    local newTank = nil

    local entries = SplitString(body, ";")
    local i
    for i = 1, table.getn(entries) do
        if entries[i] ~= "" then
            local parts = SplitString(entries[i], ":")
            local name, tankFlag, threatStr, percStr, meleeFlag = parts[1], parts[2], parts[3], parts[4], parts[5]
            if name and tankFlag and threatStr and percStr then
                local guid = nameToGuid[name] or ("THREATNAME:" .. name)
                local isTank = (tankFlag == "1")
                -- floor to a clean integer - TWThreat parses this with
                -- its own __parseint for the same reason: the raw value
                -- can come through with float noise (e.g. 71.199997)
                -- that looks broken displayed raw.
                local percNum = tonumber(percStr) or 0
                newCurrent[guid] = {
                    name = name,
                    threat = tonumber(threatStr) or 0,
                    perc = math.floor(percNum + 0.5),
                    melee = (meleeFlag == "1"),
                    tank = isTank,
                }
                if isTank then newTank = guid end
                if CL.debug then
                    CL.LogLine("[Threat]   parsed " .. name .. " guid=" .. tostring(guid) ..
                        " threat=" .. tostring(threatStr) .. " perc=" .. tostring(percStr) .. " tank=" .. tostring(isTank))
                end
            elseif CL.debug then
                CL.LogLine("[Threat]   unparseable entry: " .. tostring(entries[i]))
            end
        end
    end

    if CL.debug then CL.LogLine("[Threat] " .. table.getn(entries) .. " entries -> " .. CL.TableCount(newCurrent) .. " players resolved") end

    current = newCurrent
    tankGuid = newTank
    lastUpdate = GetTime()
    pendingTargetSince = nil

    if CL.UI and CL.UI.RefreshMode then CL.UI.RefreshMode("threat") end
end

local function RequestThreat()
    local channel = GroupChannel()
    if not channel then return end
    local requestBody = "limit=" .. REQUEST_LIMIT
    local ok, err = pcall(SendAddonMessage, REQUEST_PREFIX, requestBody, channel)
    if CL.debug then
        CL.LogLine("[Threat] request sent prefix=" .. REQUEST_PREFIX ..
            " body=" .. requestBody .. " channel=" .. channel .. " ok=" .. tostring(ok) ..
            (ok and "" or (" err=" .. tostring(err))))
    end
end

local function ThreatModeVisible()
    return CL.UI and CL.UI.IsModeVisible and CL.UI.IsModeVisible("threat")
end

-- SPELL_GO is used only for explicit DBC threat effects, never for the
-- damage already recorded by Aggregator. Keeping those two sources
-- separate prevents the Threat implementation from double-counting or
-- mutating Damage Done while still catching zero-damage threat spells.
local function HandleThreatSpellGo(spellId, casterGuid, targetGuid, numTargetsHit)
    if not ThreatModeVisible() or not IsTrackedGuid(casterGuid) then return end
    spellId = tonumber(spellId)
    if not spellId then return end

    local targetThreat, allThreat = ExplicitSpellThreat(spellId)
    if targetThreat == 0 and allThreat == 0 then return end

    -- The SPELL_GO primary target is reliable for single-target spells.
    -- If it is absent, use the live locked target as a best-effort target
    -- only for this explicit effect; ordinary damage always has its own
    -- authoritative target GUID in Aggregator.
    if not ValidGuid(targetGuid) then
        local ok, exists, liveTargetGuid = pcall(UnitExists, "target")
        if ok and exists then targetGuid = liveTargetGuid end
    end

    if targetThreat ~= 0 and ValidGuid(targetGuid) and (tonumber(numTargetsHit) or 1) > 0 then
        AddExplicitThreat(targetGuid, casterGuid, targetThreat)
    end

    if allThreat ~= 0 then
        local enc = CL.Aggregator and CL.Aggregator.GetCurrent and CL.Aggregator.GetCurrent()
        local enemies = CollectActiveEnemies(enc, targetGuid)
        local enemyGuid
        for enemyGuid in pairs(enemies) do
            AddExplicitThreat(enemyGuid, casterGuid, allThreat)
        end
    end
end

local f = CreateFrame("Frame")
f:RegisterEvent("CHAT_MSG_ADDON")
f:RegisterEvent("PARTY_MEMBERS_CHANGED")
f:RegisterEvent("RAID_ROSTER_UPDATE")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("PLAYER_REGEN_DISABLED")
f:RegisterEvent("PLAYER_REGEN_ENABLED")
f:RegisterEvent("SPELL_GO_SELF")
f:RegisterEvent("SPELL_GO_OTHER")
f:RegisterEvent("UNIT_DIED")
f:SetScript("OnEvent", function()
    if event == "PLAYER_ENTERING_WORLD" then
        explicitThreat = {}
        deadEnemies = {}
        healingSeenTotals = {}
        RefreshRosterNames()
        return
    end
    if event == "CHAT_MSG_ADDON" then
        -- arg1 = prefix, arg2 = message, arg3 = channel, arg4 = sender.
        -- The reply's real addon-message prefix (arg1) isn't "TWTv4="
        -- itself - that marker is embedded inside the message body
        -- (arg2), so that's what has to be searched, not arg1.
        if CL.debug and arg1 and (string.find(arg1, "TWT", 1, true) or (arg2 and string.find(arg2, "TWT", 1, true))) then
            CL.LogLine("[Threat] CHAT_MSG_ADDON prefix=" .. tostring(arg1) .. " from=" .. tostring(arg4) .. " msg=" .. tostring(arg2))
        end
        if arg2 and string.find(arg2, REPLY_PREFIX, 1, true) then
            local prefixPos = string.find(arg2, REPLY_PREFIX, 1, true)
            local body = string.sub(arg2, prefixPos + string.len(REPLY_PREFIX))
            HandleThreatPacket(body)
        end
        return
    end
    if event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
        RefreshRosterNames()
        return
    end
    if event == "PLAYER_REGEN_DISABLED" then
        deadEnemies = {}
        return
    end
    if event == "PLAYER_REGEN_ENABLED" then
        explicitThreat = {}
        deadEnemies = {}
        healingSeenTotals = {}
        return
    end
    if event == "UNIT_DIED" then
        if arg1 then deadEnemies[arg1] = true end
        return
    end
    if event == "SPELL_GO_SELF" or event == "SPELL_GO_OTHER" then
        -- itemId, spellId, casterGuid, targetGuid, castFlags,
        -- numTargetsHit, numTargetsMissed, corpseOwnerGuid
        HandleThreatSpellGo(arg2, arg3, arg4, arg6)
        return
    end
end)
RefreshRosterNames()

local accum = 0
local wasPolling = false
local debugAccum = 0
local lastTargetGuid = nil
f:SetScript("OnUpdate", function()
    accum = accum + arg1
    if accum < POLL_INTERVAL then return end
    accum = 0

    -- Don't bother the server at all unless some window is actually
    -- showing Threat mode right now.
    local hasUI = CL.UI and CL.UI.IsModeVisible
    local wantsThreat = hasUI and CL.UI.IsModeVisible("threat")
    local channel = wantsThreat and GroupChannel()
    local hasTargetOk, hasTarget, targetGuid, inCombat
    local polling = false
    if channel then
        hasTargetOk, hasTarget, targetGuid = pcall(UnitExists, "target")
        inCombat = hasTargetOk and hasTarget and UnitAffectingCombat("target")
        polling = inCombat
    end

    -- Target changed since the last poll (tab-targeting a different
    -- mob, retargeting after a kill, etc). The old snapshot technically
    -- belongs to whatever was targeted before, but leaving it showing
    -- until the new target's first reply lands (see pendingTargetSince
    -- above) reads far better than snap-clearing to empty and having
    -- bars pop back in ~0.5s later.
    if targetGuid ~= lastTargetGuid then
        if CL.debug then
            CL.LogLine("[Threat] target changed: " .. tostring(lastTargetGuid) .. " -> " .. tostring(targetGuid))
        end
        lastTargetGuid = targetGuid
        pendingTargetSince = GetTime()
    end

    -- New target never replied (dead before the packet came back, out
    -- of threat range, not a real mob, ...) - give up holding the old
    -- bars and actually clear.
    if pendingTargetSince and (GetTime() - pendingTargetSince) > STALE_TARGET_TIMEOUT then
        pendingTargetSince = nil
        if CL.debug then CL.LogLine("[Threat] pending target never replied - clearing") end
        current = {}
        tankGuid = nil
        if CL.UI and CL.UI.RefreshMode then CL.UI.RefreshMode("threat") end
    end

    if CL.debug then
        debugAccum = debugAccum + POLL_INTERVAL
        if polling ~= wasPolling or debugAccum >= 3 then
            debugAccum = 0
            CL.LogLine("[Threat] state: polling=" .. tostring(polling) ..
                " hasUI=" .. tostring(hasUI) .. " wantsThreat=" .. tostring(wantsThreat) ..
                " channel=" .. tostring(channel) .. " hasTargetOk=" .. tostring(hasTargetOk) ..
                " hasTarget=" .. tostring(hasTarget) .. " inCombat=" .. tostring(inCombat))
        end
    end

    if polling then
        RequestThreat()
        -- Real reply always wins when it arrives (HandleThreatPacket
        -- overwrites current/lastUpdate unconditionally) - this only
        -- fires when nothing real has landed recently, so a group that
        -- DOES get real replies never sees estimated numbers at all.
        if (GetTime() - lastUpdate) > ESTIMATE_GRACE then
            if EstimateThreat(targetGuid) then
                -- A target-specific local snapshot is a valid response
                -- for stale-display purposes. Do not clear and repopulate
                -- it on the next line after STALE_TARGET_TIMEOUT.
                pendingTargetSince = nil
            end
        end
    elseif wasPolling then
        -- Target/combat state dropped since the last poll - clear
        -- rather than leave a stale snapshot from whatever was
        -- last being fought showing in Threat mode indefinitely.
        pendingTargetSince = nil
        current = {}
        tankGuid = nil
        if CL.UI and CL.UI.RefreshMode then CL.UI.RefreshMode("threat") end
    end
    wasPolling = polling
end)

-- Sorted list of every currently-known party/raid member name (from the
-- last roster scan, independent of whether threat data has arrived yet)
-- - for UI_MainWindow.lua's Threat filter dropdown, so you can e.g. pre-
-- select yourself + the tank before combat even starts.
local function GetRosterNames()
    local names = {}
    local name, guid
    for name, guid in pairs(nameToGuid) do
        table.insert(names, name)
    end
    table.sort(names)
    return names
end

-- Same roster/naming as Aggregator.lua's TEST_ROSTER (Kobeni as the
-- "player", same class picks) so Test Mode reads as one consistent
-- preview cast across every mode, not a different fake group per tab.
-- classToken travels WITH each entry here (unlike the real snapshot,
-- which only ever carries a name/threat/perc/melee/tank - class comes
-- from CL.GuidCache.Resolve on a real GUID) since these guids aren't
-- real and GuidCache has nothing to resolve them to.
local TEST_THREAT_ROSTER = {
    { name = "Kobeni", classToken = "WARLOCK", threat = 12500, melee = false, tank = true },
    { name = "Kaladin", classToken = "WARRIOR", threat = 11800, melee = true, tank = false },
    { name = "Szeth", classToken = "ROGUE", threat = 8200, melee = true, tank = false },
    { name = "Dalinar", classToken = "PALADIN", threat = 6100, melee = true, tank = false },
    { name = "Shallan", classToken = "MAGE", threat = 4300, melee = false, tank = false },
    { name = "Jasnah", classToken = "PRIEST", threat = 3100, melee = false, tank = false },
    { name = "Adolin", classToken = "WARRIOR", threat = 2200, melee = true, tank = false },
}

-- Test Mode's stand-in for GetSnapshot() - same [guid] = {...} shape,
-- plus classToken (see above). Percentages are computed off the fake
-- tank's threat, same math the server would normally have already done
-- for the real perc field.
local function GetTestSnapshot()
    local snap = {}
    local tankThreat = TEST_THREAT_ROSTER[1].threat
    local i
    for i = 1, table.getn(TEST_THREAT_ROSTER) do
        local r = TEST_THREAT_ROSTER[i]
        snap["TESTTHREAT" .. i] = {
            name = r.name,
            classToken = r.classToken,
            threat = r.threat,
            perc = math.floor((r.threat / tankThreat) * 100 + 0.5),
            melee = r.melee,
            tank = r.tank,
        }
    end
    return snap
end

CL.Threat = {
    GetSnapshot = function() return current end,
    GetTestSnapshot = GetTestSnapshot,
    GetTankGuid = function() return tankGuid end,
    IsAvailable = function() return GroupChannel() ~= nil end,
    GetLastUpdate = function() return lastUpdate end,
    GetRosterNames = GetRosterNames,
}
