--[[
    Threat - live per-target threat.

    Primary path: this server answers a plain Blizzard addon message
    ("TWT_UDTSv4") with a reply over CHAT_MSG_ADDON (prefix "TWTv4=")
    containing every group member's current threat against your target -
    the same protocol TWThreat AND KLHThreatMeter both use, confirmed
    (by reading both addons' actual source, including KLHThreatMeter's
    dedicated KTM_TWT.lua) to need NOTHING beyond that one request - no
    handshake, no registration message, nothing addon-specific. Despite
    that, this addon alone never receives a reply unless TWThreat is
    ALSO loaded, even though its own code has zero reply-construction
    logic either (confirmed directly). Best remaining explanation: the
    server gates replies on the client's real, automatically-reported
    addon list (a standard vanilla protocol feature, unrelated to any
    SendAddonMessage content) against a small allowlist of recognized
    threat addons - not something spoofable from here.

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
local REQUEST_LIMIT = 19

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
-- see this file's header comment for why that's needed at all). Ported
-- from GreedMeter's Threat.lua (same vanilla-classic threat-mechanic
-- approximations, values reused directly - this is public game-mechanic
-- data, not anything GreedMeter-specific), adapted to read from
-- CombatLedger's own Aggregator data instead of GreedMeter's meter
-- shape.
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

-- [guid] = GetTime() of caster's most recent successful taunt (Taunt/
-- Challenging Shout/Challenging Roar/Righteous Defense - see Events.lua's
-- HandleSpellGo, the only structured signal available for a
-- non-damaging, no-debuff ability like these). The estimation below is
-- built entirely from accumulated damage/healing, which has no way to
-- reflect "the mob is now attacking whoever just taunted it" on its
-- own - without this, a tank who taunts before building any real threat
-- (a fresh pull, a threat-wipe effect) would show as having none at all,
-- and one who taunts back aggro mid-fight wouldn't visibly reclaim the
-- top spot until their real accumulated threat caught back up.
local recentTaunts = {}
-- How long a successful taunt keeps its caster pinned to (at least) the
-- current top threat value - real Taunt's own forced-attack duration is
-- ~3s, but that's the mechanic that GUARANTEES the mob attacks you, not
-- a claim that your threat reverts the instant it ends. Long enough to
-- read as "yes, the taunt worked" and give real threat generation a
-- chance to catch up before this stops propping the number up.
local TAUNT_BOOST_DURATION = 6
local TAUNT_BOOST_MULT = 1.01 -- just enough over the current top to actually rank first, not tie

local function RecordTaunt(casterGuid)
    if not casterGuid then return end
    recentTaunts[casterGuid] = GetTime()
end

local function SpellDamageThreatMult(spell)
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

-- Compute one player's estimated threat from their Aggregator unit
-- entry (damageDone/healingDone, already tracked for the meter itself -
-- no separate data collection needed). Healing counted at ~0.5x
-- effective heal, matching classic-era threat mechanics.
--
-- Returns TWO values: the owner's own threat, and separately whatever
-- their pet's melee contributed (Aggregator's petMelee/petOffhand sub-
-- buckets - see MeleeEntryFor). A pet holds its own real entry on the
-- mob's threat table, distinct from its owner's - folding it into one
-- number (which the regular damage/healing meters deliberately do, for
-- a cleaner per-player bar) would misrepresent an actual pet-tanking
-- situation here, so Threat mode keeps it split. No class-threat-mod is
-- applied to the pet's share - that modifier is a player stance/talent
-- thing, not something pet threat generation is subject to.
--
-- Known gap: this only splits pet MELEE. A pet's occasional damaging
-- spell (Imp's Firebolt, Felhunter's Shadow Bite) has no such split in
-- Aggregator's data (spellId-based damage has no isPet tag at all) and
-- stays folded into the owner's own total - not worth a data-model
-- change in Aggregator just for this edge case.
local function EstimateUnitThreat(u)
    if not u then return 0, 0 end
    local mod = 1.0
    if u.classToken and CLASS_THREAT_MOD[u.classToken] then
        mod = CLASS_THREAT_MOD[u.classToken]
    end

    local dmgThreat = 0
    if u.damageDone and u.damageDone.spells then
        local spellId, entry
        for spellId, entry in pairs(u.damageDone.spells) do
            dmgThreat = dmgThreat + (entry.total or 0) * SpellDamageThreatMult(entry.name)
        end
    end
    -- Melee entries live outside .spells (see Aggregator.lua's
    -- MeleeEntryFor) - fold in at the plain 1x rate. Pet melee/offhand
    -- are kept OUT of the owner's own total - see petThreat below.
    local petThreat = 0
    if u.damageDone then
        if u.damageDone.melee then dmgThreat = dmgThreat + (u.damageDone.melee.total or 0) end
        if u.damageDone.offhand then dmgThreat = dmgThreat + (u.damageDone.offhand.total or 0) end
        if u.damageDone.petMelee then petThreat = petThreat + (u.damageDone.petMelee.total or 0) end
        if u.damageDone.petOffhand then petThreat = petThreat + (u.damageDone.petOffhand.total or 0) end
    end

    local healThreat = 0
    if u.healingDone then
        healThreat = (u.healingDone.total or 0) * 0.5
    end

    return (dmgThreat + healThreat) * mod, petThreat
end

-- Populates current/tankGuid from CombatLedger's own live encounter
-- data (CL.Aggregator.GetCurrent().units) instead of a server reply.
-- Same output shape HandleThreatPacket produces, so the UI needs no
-- changes to consume either source.
local function EstimateThreat()
    local enc = CL.Aggregator and CL.Aggregator.GetCurrent and CL.Aggregator.GetCurrent()
    if not enc or not enc.units then return false end

    -- Pass 1: plain accumulated-damage/healing threat, exactly as before -
    -- also the baseline a taunt boost (pass 2) needs to know it has to
    -- beat. A unit with a live taunt but zero raw threat (a taunt cast
    -- before anyone's landed a hit yet) still needs a slot here to
    -- receive that boost, so the inclusion check covers both cases
    -- rather than just "threat > 0".
    local now = GetTime()
    local raw = {}
    local rawMax = 0
    local guid, u
    for guid, u in pairs(enc.units) do
        local threat, petThreat = EstimateUnitThreat(u)
        local taunted = recentTaunts[guid] and (now - recentTaunts[guid]) < TAUNT_BOOST_DURATION
        if threat > 0 or taunted then
            raw[guid] = { name = u.name or guid, threat = threat, taunted = taunted }
            if threat > rawMax then rawMax = threat end
        end
        if petThreat > 0 then
            -- Own slot, own key - never merged into the owner's entry
            -- above. Keyed by the pet's real guid when the roster scan
            -- currently has one on file (CL.GuidCache.Resolve then gives
            -- it a real name/class like any other unit), falling back to
            -- a synthetic key + "OwnerName's Pet" when it doesn't (pet
            -- dismissed/out of range right now, but it still dealt
            -- damage earlier this fight). Never taunt-boosted - taunts
            -- are recorded by casterGuid and a pet's own Growl isn't a
            -- tracked taunt source here, out of scope for this split.
            local petGuid = CL.GuidCache and CL.GuidCache.GetPetGuid and CL.GuidCache.GetPetGuid(guid)
            local petInfo = petGuid and CL.GuidCache.Resolve(petGuid)
            local petKey = petGuid or ("PET:" .. guid)
            local petName = (petInfo and petInfo.name) or ((u.name or guid) .. "'s Pet")
            raw[petKey] = { name = petName, threat = petThreat, taunted = false }
            if petThreat > rawMax then rawMax = petThreat end
        end
    end
    if not next(raw) then return false end

    -- Pass 2: a live taunt pins its caster to (at least) the current top
    -- threat value - see RecordTaunt's own comment for why the estimator
    -- can't derive this from damage/healing data alone. Floored at 1 so
    -- a taunt landed before anyone's dealt any damage yet still shows
    -- SOME threat instead of tying everyone else at zero.
    for guid, entry in pairs(raw) do
        if entry.taunted then
            entry.threat = math.max(entry.threat, rawMax * TAUNT_BOOST_MULT, 1)
        end
    end

    local newCurrent = {}
    local maxThreat = 0
    for guid, entry in pairs(raw) do
        if entry.threat > 0 then
            newCurrent[guid] = { name = entry.name, threat = entry.threat, estimated = true }
            if entry.threat > maxThreat then maxThreat = entry.threat end
        end
    end

    if maxThreat <= 0 then return false end

    local newTank = nil
    local maxSeen = 0
    for guid, entry in pairs(newCurrent) do
        entry.perc = math.floor((entry.threat / maxThreat) * 100 + 0.5)
        entry.melee = false
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
        CL.LogLine("[Threat] estimated " .. CL.TableCount(newCurrent) .. " players (no real reply for " ..
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

-- Also scans pet tokens (GuidCache.lua's own convention: "pet",
-- "partypetN", "raidNpet") - not because the real TWT protocol is known
-- to ever name a pet as its own entry (this file's header comment
-- already confirms it only ever names party/raid members), but so that
-- IF a server-side variant ever does, that name resolves to a real guid
-- here instead of falling back to HandleThreatPacket's synthetic
-- "THREATNAME:" key. Also makes pet names available in GetRosterNames'
-- Threat filter dropdown for free, so a filtered view doesn't silently
-- drop the split-out pet row from EstimateThreat above.
local function RefreshRosterNames()
    nameToGuid = {}
    AddRosterName("player")
    AddRosterName("pet")
    if GetNumRaidMembers and GetNumRaidMembers() > 0 then
        local i
        for i = 1, 40 do
            AddRosterName("raid" .. i)
            AddRosterName("raid" .. i .. "pet")
        end
    elseif GetNumPartyMembers and GetNumPartyMembers() > 0 then
        local i
        for i = 1, 4 do
            AddRosterName("party" .. i)
            AddRosterName("partypet" .. i)
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
    local ok, err = pcall(SendAddonMessage, REQUEST_PREFIX, "limit=" .. REQUEST_LIMIT, channel)
    if CL.debug then
        CL.LogLine("[Threat] request sent prefix=" .. REQUEST_PREFIX .. " channel=" .. channel .. " ok=" .. tostring(ok) .. (ok and "" or (" err=" .. tostring(err))))
    end
end

local f = CreateFrame("Frame")
f:RegisterEvent("CHAT_MSG_ADDON")
f:RegisterEvent("PARTY_MEMBERS_CHANGED")
f:RegisterEvent("RAID_ROSTER_UPDATE")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:SetScript("OnEvent", function()
    if event == "PLAYER_ENTERING_WORLD" then
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
    RefreshRosterNames()
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
            EstimateThreat()
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
    RecordTaunt = RecordTaunt,
    GetSnapshot = function() return current end,
    GetTestSnapshot = GetTestSnapshot,
    GetTankGuid = function() return tankGuid end,
    IsAvailable = function() return GroupChannel() ~= nil end,
    GetLastUpdate = function() return lastUpdate end,
    GetRosterNames = GetRosterNames,
}
