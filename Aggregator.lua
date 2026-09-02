--[[
    Aggregator - encounter lifecycle and per-unit/per-spell recording.

    One data shape for the live encounter, the session-long "Overall"
    accumulator, and saved history, so the breakdown window can render
    any of them without duplicate code:

        encounter = {
            label, zone, startTime, timestamp, duration,
            units = {
                [guid] = {
                    name, class, isPlayer,
                    damageDone  = { total, spells = { [spellId] = {name, school, hits, crits, total, min, max} }, melee = {hits, crits, total, min, max} },
                    healingDone = { total, overheal, spells = { ... } },
                    damageTaken = { total, spells = { ... }, melee = { ... } },
                    deaths,
                },
            },
        }

    Melee (spellId == nil) is recorded into `.melee` instead of `.spells`
    so it doesn't need a fake spell ID.

    Every Record* call writes into BOTH `current` (the live fight, reset
    per encounter) and `overall` (a running total since login/last
    manual reset) - two independent unit tables receiving the same
    events, not one feeding the other.
]]

local CL = CombatLedger

local current = nil -- the live encounter, or nil if not in one

-- startTime uses GetTime() (session-relative float, matches what the live
-- meter and PrintStatus subtract it against for elapsed/DPS math) - not
-- time() (epoch seconds): a time()-based startTime would make
-- GetTime() - startTime a huge negative number, silently pinning every
-- live duration read to the "<= 0" fallback of 1 second forever.
local function NewEncounter()
    return {
        label = nil,
        zone = (GetRealZoneText and GetRealZoneText()) or "",
        startTime = GetTime(),
        -- Wall-clock companion to startTime, used only by RestoreState's
        -- staleness check below - see that comment for why GetTime()
        -- alone isn't safe there.
        startTimeReal = time(),
        units = {},
        activeDuration = 0, -- only meaningful for `overall` (see GetOverallDuration) - sum of finished encounters' durations, so idle time between pulls doesn't dilute Overall DPS
        pullBy = nil, -- { name, label } - set once, from whoever's action started this encounter
        mobTally = {}, -- [guid] = damage dealt to it by tracked casters - label-only, not a real bar entry (mobs are deliberately excluded from units)
        mobHealth = {}, -- [guid] = highest UnitHealthMax(guid) sampled for it - label-only, same reasoning as mobTally (see History.lua's ComputeLabel)
        -- Raid-wide shape-of-the-fight, for UI_EncounterReport's graph.
        -- Fixed-width time buckets (see RecordSeriesPoint), not a raw
        -- per-event log: a whole fight's worth of events at ~2500 events/
        -- encounter x up to 50 saved encounters would make
        -- CombatLedgerDB.lua noticeably bloat and slow to parse on
        -- login, where a bucketed series stays a few hundred small
        -- tables even for a long fight. The cost is that the report
        -- can't scrub to "what exactly landed at 1:23" the way a full
        -- event log could - only the live DeathRecap buffer keeps that
        -- level of per-event detail, and only for the last 10s per unit.
        series = {},
        -- Set true the moment this encounter's enemy is confirmed
        -- boss-tagged (see IsBossTaggedEnemy) - drives both which History
        -- bucket the finished encounter gets saved into (History.lua's
        -- separate per-boss-name bucket, not the regular capped list -
        -- see SaveBossEncounter) and whether abilitySeries below gets
        -- populated at all.
        isBossFight = false,
        -- Raid-wide damage-by-ability-per-second, ONLY collected for boss
        -- fights (see RecordAbilitySeriesPoint) - a real per-encounter
        -- feature (History's Bosses tab report graphs "each ability as
        -- its own line"), not something worth the memory/CPU cost for
        -- every random trash pull the way `series` above already is.
        -- [bucketIdx] = { [spellKey] = amount } - one bucket per second.
        abilitySeries = {},
        abilityNames = {}, -- [spellKey] = display name, for the graph legend
        abilityTotals = {}, -- [spellKey] = grand total across the whole fight, for ranking/top-N selection
    }
end

-- One shared bucket width for every encounter's series - only current
-- (not overall) ever gets buckets recorded into it, since Overall isn't
-- a single bounded fight and graphing "since login" wouldn't mean much.
local TIMELINE_BUCKET_SECONDS = 2

local function RecordSeriesPoint(enc, kind, amount)
    if not enc or not enc.startTime or not enc.series then return end
    local elapsed = GetTime() - enc.startTime
    local idx = math.floor(elapsed / TIMELINE_BUCKET_SECONDS) + 1
    if idx < 1 then idx = 1 end
    local bucket = enc.series[idx]
    if not bucket then
        bucket = { damage = 0, healing = 0, taken = 0 }
        enc.series[idx] = bucket
    end
    bucket[kind] = (bucket[kind] or 0) + amount
end

-- Melee/off-hand have no spellId to key by - reuses this file's existing
-- convention (see Threat.lua's REFLECT_SPELL_ID) of a negative sentinel
-- standing in for "not a real spellId" instead of colliding with one.
local MELEE_ABILITY_KEY = -1
local OFFHAND_ABILITY_KEY = -2

-- 1s resolution (finer than the 2s TIMELINE_BUCKET_SECONDS above) - "by
-- second" was explicit in the ask, and this only ever runs for boss
-- fights (a handful of saved kills, not every trash pull), so the extra
-- granularity doesn't carry the same bloat risk `series` was built to
-- avoid. UI_EncounterReport.lua downsamples for display the same way it
-- already downsamples `series`, so the render cost stays flat regardless
-- of fight length.
local ABILITY_BUCKET_SECONDS = 1

local function RecordAbilitySeriesPoint(enc, spellKey, spellName, amount)
    if not enc or not enc.isBossFight or not enc.startTime then return end
    if not enc.abilitySeries then enc.abilitySeries = {} end
    if not enc.abilityNames then enc.abilityNames = {} end
    if not enc.abilityTotals then enc.abilityTotals = {} end

    local elapsed = GetTime() - enc.startTime
    local idx = math.floor(elapsed / ABILITY_BUCKET_SECONDS) + 1
    if idx < 1 then idx = 1 end
    local bucket = enc.abilitySeries[idx]
    if not bucket then
        bucket = {}
        enc.abilitySeries[idx] = bucket
    end
    bucket[spellKey] = (bucket[spellKey] or 0) + amount
    enc.abilityNames[spellKey] = spellName
    enc.abilityTotals[spellKey] = (enc.abilityTotals[spellKey] or 0) + amount
end

local overall = NewEncounter() -- long-lived; only cleared by ResetOverall()

-- Death recap: a short rolling per-unit hit history, independent of the
-- aggregated totals above - "what actually killed me in the last few
-- seconds", which needs the raw sequence, not a sum. Nampower's GUID
-- resolution is what makes attributing each hit to a real attacker name
-- reliable here; chat-text parsing can't do this nearly as cleanly.
local RECAP_WINDOW = 10 -- seconds of history kept per tracked unit
local recapBuffers = {} -- [guid] = { {time, attacker, label, amount, isCrit}, ... }, oldest first
local lastDeathRecap = {} -- [guid] = { deathTime, hits = {...snapshot...} }

local function RecordRecapHit(guid, attacker, label, amount, isCrit)
    local buf = recapBuffers[guid]
    if not buf then
        buf = {}
        recapBuffers[guid] = buf
    end
    table.insert(buf, { time = GetTime(), attacker = attacker, label = label, amount = amount, isCrit = isCrit })

    local cutoff = GetTime() - RECAP_WINDOW
    while table.getn(buf) > 0 and buf[1].time < cutoff do
        table.remove(buf, 1)
    end
end

local function SnapshotDeathRecap(guid)
    local buf = recapBuffers[guid]
    local copy = {}
    if buf then
        local i
        for i = 1, table.getn(buf) do
            copy[i] = buf[i]
        end
    end
    lastDeathRecap[guid] = { deathTime = GetTime(), hits = copy }
end

local function GetDeathRecap(guid)
    return guid and lastDeathRecap[guid]
end

local function NewAvoided()
    return { miss = 0, dodge = 0, parry = 0, block = 0, evade = 0, immune = 0, deflect = 0, other = 0 }
end

-- Avoidance only ever applies to melee (see RecordAvoidance - AUTO_ATTACK
-- is the only source of it on this server), so it lives on the
-- melee/petMelee entry itself rather than the whole bucket - that's what
-- lets the breakdown window's hover show "this ability's" own dodge/
-- parry/miss numbers instead of a bucket-wide total that doesn't
-- actually belong to any one ability.
local function NewMeleeEntry()
    return { hits = 0, crits = 0, total = 0, critTotal = 0, min = nil, max = nil, avoided = NewAvoided() }
end

local function NewBucket()
    return {
        total = 0,
        spells = {},
        melee = NewMeleeEntry(),
        -- Off-hand swings carry hitInfo's 0x04 bit same as everything
        -- else, so a dual-wielder's off-hand is trackable as its own
        -- line rather than blending into "Melee".
        offhand = NewMeleeEntry(),
        -- Pet melee is bucketed separately from the owner's own melee -
        -- both roll into the same unit/total (see AttributedGuid), but a
        -- caster's "Auto Attack" line showing pet swings they never threw
        -- themselves is misleading in the breakdown window.
        petMelee = NewMeleeEntry(),
        petOffhand = NewMeleeEntry(),
        -- Only populated for damageDone: who this damage actually landed
        -- on, [targetGuid] = { name, total, hits } - lets the breakdown
        -- window answer "did this damage go to the boss, or somewhere
        -- else" (padding on trash instead of the actual target).
        targets = {},
    }
end

-- Pets roll up under their owner's bar (a Hunter's or Warlock's pet
-- damage reads as "theirs" in every real meter) rather than showing as
-- a separate row - redirect the guid used for bucketing, but only that;
-- IsRelevant/roster checks elsewhere still key off the pet's own guid.
local function AttributedGuid(guid)
    if CL.GuidCache and CL.GuidCache.GetOwner then
        local owner = CL.GuidCache.GetOwner(guid)
        if owner then return owner end
    end
    return guid
end

local function EnsureUnit(units, guid)
    local u = units[guid]
    if not u then
        local info = CL.GuidCache and CL.GuidCache.Resolve(guid)
        u = {
            name = (info and info.name) or guid,
            class = info and info.class,
            classToken = info and info.classToken,
            isPlayer = info and info.isPlayer,
            damageDone = NewBucket(),
            -- `targets` here is who was healed (recipients), same idea
            -- as damageDone.targets - lets the breakdown window answer
            -- "who did this healing actually go to" the same way it
            -- already answers "who did this damage actually go to".
            healingDone = { total = 0, overheal = 0, spells = {}, targets = {} },
            damageTaken = NewBucket(),
            -- Dispels/cleanses - total is a COUNT (not an amount), same
            -- bucket shape (spells/targets) as everything else so the
            -- breakdown window's generic code works unmodified. Built on
            -- SPELL_DISPEL_BY_SELF/OTHER (casterGuid, targetGuid,
            -- spellId), not text parsing, so there's no cast/fade
            -- correlation heuristic needed to avoid miscounting a
            -- natural expiration.
            cleanses = { total = 0, spells = {}, targets = {} },
            -- Debuffs given - same count-only shape as cleanses. Built
            -- by correlating AURA_CAST_ON_* (has caster+target, no
            -- reliable buff/debuff classification) with the immediately-
            -- following DEBUFF_ADDED_* (has the reliable classification,
            -- no caster) by matching (targetGuid, spellId) - see
            -- Events.lua's correlation buffer. Buffs Given was built the
            -- same way but is hidden: prebuffing happens out of combat,
            -- before the encounter it was for even starts, so it
            -- doesn't fit this addon's per-encounter model; a live
            -- "which raid buffs is each person missing" checker is a
            -- different, deferred feature.
            debuffsGiven = { total = 0, spells = {}, targets = {} },
            -- Interrupts - same count-only shape again, built on two
            -- separate signals (see Events.lua): a TRUE signal for melee
            -- "special attack" interrupts (Kick/Pummel) via AUTO_ATTACK's
            -- victimState field, and a known-spell-name heuristic for
            -- pure spell-cast interrupts (Counterspell/Spell Lock, which
            -- deal no damage and have no dedicated interrupt event from
            -- Nampower - same tradeoff GreedMeter's own interrupt tracker
            -- accepts, just built on a structured SPELL_GO landing
            -- instead of parsing a chat message).
            interrupts = { total = 0, spells = {}, targets = {} },
            deaths = 0,
        }
        units[guid] = u
    end
    return u
end

local function EnsureSpellEntry(spells, spellId, name, school)
    local s = spells[spellId]
    if not s then
        s = { name = name, school = school, hits = 0, crits = 0, total = 0, critTotal = 0, min = nil, max = nil }
        spells[spellId] = s
    else
        -- RecordCast can create this entry first (a DoT's AURA_CAST
        -- fires before its first tick), with no school known yet -
        -- backfill once real damage data supplies it, instead of
        -- leaving it permanently nil.
        if name and not s.name then s.name = name end
        if school and not s.school then s.school = school end
    end
    return s
end

local function RecordHit(entry, amount, isCrit)
    entry.hits = entry.hits + 1
    entry.total = entry.total + amount
    if isCrit then
        entry.crits = entry.crits + 1
        entry.critTotal = (entry.critTotal or 0) + amount
    end
    if not entry.min or amount < entry.min then entry.min = amount end
    if not entry.max or amount > entry.max then entry.max = amount end
end

-- Lazily creates a same-shaped sub-bucket on a spell entry, keyed
-- "directHits" or "tickHits" - see RecordDamageInto's isPeriodic
-- threading. Kept entirely separate from (and additive to) the spell
-- entry's own top-level RecordHit call, which stays the combined
-- hit+tick total exactly as before - nothing that already reads
-- entry.total/.hits/.min/.max (bar sorting, DPS math, "Top Ability")
-- needs to change or even know this split exists. This is purely for
-- UI_BreakdownWindow.lua to show separate Hits/Ticks lines under a
-- spell that has both, since a DoT tick can never crit but its
-- initial hit can - mixing the two into one min/max produced reports
-- that read as "weird" (e.g. Rake/Immolate) without ever actually
-- being wrong, just conflating two different kinds of numbers.
local function EnsureSplitBucket(entry, key)
    local b = entry[key]
    if not b then
        b = { hits = 0, crits = 0, total = 0, critTotal = 0, min = nil, max = nil }
        entry[key] = b
    end
    return b
end

local lastFinished = nil -- frozen snapshot of the previous fight, shown as "Current Fight" between pulls
local lastFinishedTime = nil -- GetTime() when lastFinished was set - see ShouldLazyStart below

local function StartEncounter()
    if current then return end
    current = NewEncounter()
    lastFinished = nil -- a new fight is live - stop showing the frozen previous one
    if CL.debug then
        CL.Print("Encounter started.")
        CL.LogLine("[REGEN] StartEncounter (lazy-start guard passed or real PLAYER_REGEN_DISABLED)")
    end
end

-- Guards every Record*'s lazy "if not current then StartEncounter()" -
-- without this, a stray post-combat event (a HoT finishing its last
-- tick, a top-off heal, a DoT's last tick landing late, splash damage
-- from something already resolved) spins up a brand new BLANK encounter
-- out of thin air the moment the real fight's encounter has already
-- ended, purely because something still called Record* after current
-- went nil. Since UI_MainWindow.lua's "Current Fight" display prefers
-- current over the frozen lastFinished the instant current exists again
-- (see GetCurrentDisplay below), that phantom encounter doesn't just
-- sit there quietly - it immediately overwrites the just-finished
-- fight's summary with an empty one, which is exactly what looked like
-- "the stop isn't instant" (the fight really did end fine; a trailing
-- event just erased the result a moment later).
--
-- Used to be skipped for RecordDamage/RecordAvoidance/RecordInterrupt/
-- RecordDebuffGiven specifically, on the theory that gating on combat
-- risked dropping the first hit of a fresh pull if UnitAffectingCombat
-- hadn't flipped true yet. That theory DID pan out after all, confirmed
-- via debug log against a training dummy: dummies here don't reliably
-- flip the player's own combat flag at all, so gating unconditionally
-- on it dropped a real spell's entire initial hit (Immolate's opening
-- burn, 334 of its 1044 total) every single time - the encounter's
-- FIRST event is exactly the one this guard can't afford to reject.
--
-- Checks the PLAYER's own combat flag specifically, NOT the whole
-- group's - used to check raid/party members too, which reintroduced
-- the exact bug this guard exists to prevent: your own fight ends
-- (current freezes into lastFinished), but a groupmate is still
-- fighting, so their trailing damage/heal event still passed the
-- "someone's in combat" check and restarted a blank encounter right
-- on top of your just-finished result. GreedMeter (this addon's own
-- reference point) ties recording to the player's own personal combat
-- state exactly like this, not the raid's - matching that.
local function IsPlayerInCombat()
    local ok, playerCombat = pcall(UnitAffectingCombat, "player")
    return ok and playerCombat and true or false
end

-- The actual guard every Record*'s lazy "if not current then
-- StartEncounter()" uses (see above) - combines both fixes instead of
-- picking one at the other's expense. IsPlayerInCombat() alone always
-- passes; the phantom-encounter risk only ever came from a stray
-- TRAILING event shortly after a real fight just ended, not from a
-- genuine fresh pull. So: allow immediately if the player's combat flag
-- already agrees, OR if it's been a while (no encounter recently ended,
-- or long enough since one did) - only refuse in the narrow window
-- right after lastFinished was set, where a still-unflagged hit is far
-- more likely a trailing tick than a real new pull.
--
-- IsPlayerInCombat() itself isn't perfectly clean evidence, though -
-- confirmed via debug log: a mob's Cloud of Disease ground effect kept
-- ticking the player 2s after that same mob's fight had already ended,
-- which flips UnitAffectingCombat true for that instant same as a real
-- swing would. caster/targetGuid (when the caller has them) catch this
-- one: within the guard window, a hit involving someone who was already
-- a participant in the fight that just ended is far more likely that
-- fight's own residue (a lingering DoT/cloud, a delayed tick) than a
-- fresh pull, so it's refused even though the flag says otherwise. A
-- genuinely new pull's mob was never in lastFinished.units and sails
-- through untouched.
local PHANTOM_GUARD_WINDOW = 3 -- seconds after a fight ends where an unflagged hit is treated as a trailing event, not a new pull
local function ShouldLazyStart(casterGuid, targetGuid)
    local withinGuardWindow = lastFinishedTime and (GetTime() - lastFinishedTime) < PHANTOM_GUARD_WINDOW
    if withinGuardWindow and lastFinished and lastFinished.units
        and ((casterGuid and lastFinished.units[casterGuid]) or (targetGuid and lastFinished.units[targetGuid])) then
        return false
    end
    if IsPlayerInCombat() then return true end
    if withinGuardWindow then return false end
    return true
end

local function GetCurrent()
    return current
end

-- What "Current Fight" should actually display: the live encounter
-- while one's running, otherwise the last one that finished (frozen,
-- not cleared) until the next pull starts. Without this, Current Fight
-- would go blank the instant the grace/idle timeout ends the encounter,
-- rather than staying up to review like Details/Skada do.
local function GetCurrentDisplay()
    return current or lastFinished
end

local function GetOverall()
    return overall
end

local function ResetOverall()
    overall = NewEncounter()
end

-- Defensive backfill for a unit restored from SavedVariables - a save
-- written before some field existed (e.g. cleanses/debuffsGiven, or the
-- .targets recipient tracking added onto healingDone/damageTaken) would
-- otherwise nil-index the first time a Record* call touches that field.
-- Same "new fields need defensive re-init" pattern as
-- CL.GetSetting/CL.GetLayout's EnsureXTable in Core.lua, just per-unit
-- instead of per-SavedVariable.
local function BackfillUnit(u)
    if not u.damageDone then u.damageDone = NewBucket() end
    if not u.damageDone.targets then u.damageDone.targets = {} end
    if not u.healingDone then u.healingDone = { total = 0, overheal = 0, spells = {}, targets = {} } end
    if not u.healingDone.targets then u.healingDone.targets = {} end
    if not u.damageTaken then u.damageTaken = NewBucket() end
    if not u.damageTaken.targets then u.damageTaken.targets = {} end
    if not u.cleanses then u.cleanses = { total = 0, spells = {}, targets = {} } end
    if not u.debuffsGiven then u.debuffsGiven = { total = 0, spells = {}, targets = {} } end
    if not u.interrupts then u.interrupts = { total = 0, spells = {}, targets = {} } end
    if not u.deaths then u.deaths = 0 end
end

local function BackfillEncounter(enc)
    if not enc then return end
    -- Encounter-level scratch fields added after this encounter may not
    -- have been serialized (mobHealth) - without this, a `current`
    -- restored across a /reload from an older save would nil-index the
    -- moment RecordDamage's health sampler touched it.
    if not enc.mobTally then enc.mobTally = {} end
    if not enc.mobHealth then enc.mobHealth = {} end
    if not enc.series then enc.series = {} end
    if not enc.units then return end
    local guid, u
    for guid, u in pairs(enc.units) do
        BackfillUnit(u)
    end
end

-- Saved to CombatLedgerDB.liveState on PLAYER_LOGOUT (which vanilla also
-- fires on /reload, not just a real logout) and restored on the next
-- PLAYER_ENTERING_WORLD - see Events.lua. Without this, a mid-raid
-- /reload would silently wipe the in-progress fight and the whole
-- session's Overall totals back to zero, since current/overall only
-- exist as Lua locals otherwise.
local function SerializeState()
    return { current = current, overall = overall }
end

-- `current`'s startTime is a GetTime() value from the PREVIOUS process -
-- valid across a same-process /reload (GetTime() keeps counting, since
-- /reload only rebuilds the Lua environment, not the game client
-- process), but not across a real logout/relogin (GetTime() resets to
-- ~0 on a fresh client launch). The original check here was
-- "startTime <= GetTime()", meant to reject a startTime that would
-- otherwise land in the future - but that's not actually a same-process
-- test: a fresh launch's GetTime() ALSO starts small, so an old
-- encounter that itself started early in ITS session (small startTime)
-- can trivially satisfy "<= GetTime()" again on a brand new process
-- once even a few seconds have ticked since login, and get wrongly
-- restored as still-live. That silently absorbed the real session's
-- first hit into the stale encounter (which the idle timeout then
-- finishes/discards before the real pull even starts) - reported as
-- "the first hit of a new session doesn't get recorded", easy to hit
-- while testing this exact behavior (attack once, relaunch to check,
-- repeat - each of those old sessions has a small startTime by
-- construction). startTimeReal (time(), wall-clock) doesn't have this
-- problem - it never resets across any boundary, reload or relaunch -
-- so "was this saved within the last few minutes" is a real same-
-- process test instead of a coincidental number comparison. Missing
-- startTimeReal (older saved data, before this field existed) is
-- treated as stale/reject, same as the original conservative default.
-- overall doesn't have this problem (activeDuration is just an
-- accumulated number, not a GetTime()-relative one).
local RESTORE_STALE_SECONDS = 300
local function RestoreState(saved)
    if not saved then return end
    if saved.overall then
        overall = saved.overall
        BackfillEncounter(overall)
    end
    if saved.current and saved.current.startTimeReal
        and (time() - saved.current.startTimeReal) < RESTORE_STALE_SECONDS
        and saved.current.startTime and saved.current.startTime <= GetTime() then
        current = saved.current
        BackfillEncounter(current)
    end
end

-- Overall's displayed duration should only advance while actually
-- fighting, not across idle gaps between pulls (otherwise standing
-- around between fights keeps diluting Overall DPS). accumulated
-- finished-fight time, plus the live in-progress fight if there is one.
local function GetOverallDuration()
    local d = overall.activeDuration or 0
    if current then
        d = d + (GetTime() - current.startTime)
    end
    return d
end

-- lastActivityTime (Events.lua's own lastEventTime, touched by every
-- relevant combat event) trims trailing idle time out of the reported
-- duration - PLAYER_REGEN_ENABLED can fire well after the last real hit
-- (standing around still "in combat" for other reasons, a slow-to-clear
-- flag, waiting out the grace window), which was inflating duration and
-- understating DPS/rate for every mode. GreedMeter (this addon's own
-- reference point) does exactly this same trim in its own
-- Parser:OnCombatEnd - matching it is why a side-by-side comparison
-- kept showing a shorter GreedMeter duration for the identical fight.
-- Only ever shrinks duration, never extends it, and only when the last
-- activity actually falls inside this encounter's own span.
local function EndEncounter(lastActivityTime)
    if not current then return nil end
    current.duration = GetTime() - current.startTime
    if lastActivityTime and lastActivityTime >= current.startTime and lastActivityTime < GetTime() then
        local trimmed = lastActivityTime - current.startTime
        if trimmed > 0 and trimmed < current.duration then
            current.duration = trimmed
        end
    end
    current.timestamp = time()
    overall.activeDuration = (overall.activeDuration or 0) + current.duration
    local finished = current
    current = nil
    lastFinished = finished
    lastFinishedTime = GetTime()
    return finished
end

local function IsTrackedGuid(guid)
    return guid and CL.GuidCache and CL.GuidCache.IsTracked(guid)
end

-- Which side of a caster/target pair is the enemy (not on our roster) -
-- shared by the pull-announcement classification check below and
-- RecordDamage's own mob tally/health population further down.
local function EnemyGuidFor(casterGuid, targetGuid)
    if casterGuid and targetGuid and IsTrackedGuid(AttributedGuid(casterGuid)) then
        return AttributedGuid(targetGuid)
    elseif casterGuid and targetGuid and IsTrackedGuid(AttributedGuid(targetGuid)) then
        return AttributedGuid(casterGuid)
    end
    return nil
end

-- This client's SuperWoW lets a raw GUID stand in for a unit token
-- directly (see GuidCache.lua/RecordDamage's own UnitHealthMax use) -
-- UnitClassification(guid)/UnitLevel(guid) resolve right here the same
-- way, as long as the enemy is actually in range, which it is by
-- definition (we just recorded a hit involving it).
--
-- Plain "elite" alone (TWThreat's own restriction, which this used to
-- just mirror) catches every elite trash pack too, not just real
-- bosses - most vanilla instance bosses aren't actually classified
-- "worldboss" (that classification is mostly reserved for open-world
-- named bosses like Onyxia), so a real boss is identified here as
-- EITHER worldboss, OR elite/rareelite with no real level shown
-- ("??", UnitLevel returning -1) - the common heuristic other addons
-- use, since regular elite trash almost always has a real numeric
-- level.
local function IsBossTaggedEnemy(enemyGuid)
    if not enemyGuid or not UnitClassification then return false end
    local ok, classification = pcall(UnitClassification, enemyGuid)
    if not ok then
        if CL.debug then
            CL.LogLine(string.format("[BOSS_CHECK] guid=%s UnitClassification pcall failed", tostring(enemyGuid)))
        end
        return false
    end
    local isBoss = false
    local level
    if classification == "worldboss" then
        isBoss = true
    elseif classification == "elite" or classification == "rareelite" then
        local lvlOk, lvl = pcall(UnitLevel, enemyGuid)
        level = lvlOk and lvl
        isBoss = lvlOk and lvl == -1
    end
    if CL.debug then
        CL.LogLine(string.format("[BOSS_CHECK] guid=%s classification=%s level=%s isBoss=%s",
            tostring(enemyGuid), tostring(classification), tostring(level), tostring(isBoss)))
    end
    return isBoss
end

-- Which melee sub-entry a dmg=0-or-not auto-attack swing belongs in -
-- shared by RecordDamageInto and RecordAvoidanceInto so main-hand/
-- off-hand/pet routing stays in exactly one place.
local function MeleeEntryFor(bucket, isPet, isOffhand)
    if isPet then
        return isOffhand and bucket.petOffhand or bucket.petMelee
    end
    return isOffhand and bucket.offhand or bucket.melee
end

-- casterGuid/targetGuid may each independently be nil (unattributable
-- source or target) - record whichever side we actually have. Only ever
-- for roster members though: a bar list should show "us", not whatever
-- mob happens to be on the other end of the hit (a mob dealing damage
-- to you is not a "Damage Done" entry for the mob, and a mob you're
-- hitting is not a "Damage Taken" entry for the mob).
local function RecordDamageInto(units, casterGuid, targetGuid, spellId, spellName, school, amount, isCrit, isOffhand, isPeriodic)
    if casterGuid then
        local attributed = AttributedGuid(casterGuid)
        if IsTrackedGuid(attributed) then
            local u = EnsureUnit(units, attributed)
            u.damageDone.total = u.damageDone.total + amount
            if spellId then
                local entry = EnsureSpellEntry(u.damageDone.spells, spellId, spellName, school)
                -- A DoT's AURA_CAST (see RecordCast) can land before this
                -- entry exists - fold in whatever cast count was stashed
                -- waiting for it, once, right when the entry is born.
                if u.pendingCasts and u.pendingCasts[spellId] then
                    entry.casts = (entry.casts or 0) + u.pendingCasts[spellId]
                    u.pendingCasts[spellId] = nil
                end
                RecordHit(entry, amount, isCrit)
                RecordHit(EnsureSplitBucket(entry, isPeriodic and "tickHits" or "directHits"), amount, isCrit)
            else
                RecordHit(MeleeEntryFor(u.damageDone, attributed ~= casterGuid, isOffhand), amount, isCrit)
            end

            if targetGuid then
                local t = u.damageDone.targets[targetGuid]
                if not t then
                    local tinfo = CL.GuidCache and CL.GuidCache.Resolve(targetGuid)
                    -- Same shape as a damage bucket (spells/melee/offhand/
                    -- pet variants) so clicking this target in the UI can
                    -- reuse the exact same per-ability breakdown code as
                    -- the unit-wide view, just scoped to this one target.
                    t = {
                        name = (tinfo and tinfo.name) or targetGuid,
                        total = 0,
                        hits = 0,
                        spells = {},
                        melee = NewMeleeEntry(),
                        offhand = NewMeleeEntry(),
                        petMelee = NewMeleeEntry(),
                        petOffhand = NewMeleeEntry(),
                    }
                    u.damageDone.targets[targetGuid] = t
                end
                t.total = t.total + amount
                t.hits = t.hits + 1
                if spellId then
                    local entry = EnsureSpellEntry(t.spells, spellId, spellName, school)
                    RecordHit(entry, amount, isCrit)
                    RecordHit(EnsureSplitBucket(entry, isPeriodic and "tickHits" or "directHits"), amount, isCrit)
                else
                    RecordHit(MeleeEntryFor(t, attributed ~= casterGuid, isOffhand), amount, isCrit)
                end
            end
        end
    end

    if targetGuid then
        local attributed = AttributedGuid(targetGuid)
        if IsTrackedGuid(attributed) then
            local u = EnsureUnit(units, attributed)
            u.damageTaken.total = u.damageTaken.total + amount
            if spellId then
                local entry = EnsureSpellEntry(u.damageTaken.spells, spellId, spellName, school)
                RecordHit(entry, amount, isCrit)
                RecordHit(EnsureSplitBucket(entry, isPeriodic and "tickHits" or "directHits"), amount, isCrit)
            else
                RecordHit(MeleeEntryFor(u.damageTaken, attributed ~= targetGuid, isOffhand), amount, isCrit)
            end

            -- Who this damage actually came from (reuses damageTaken's
            -- own `targets` field, same bucket-shaped-entry trick as
            -- damageDone.targets) - the breakdown window shows this as
            -- "Attackers:" instead of "Targets:" for this mode.
            if casterGuid then
                local s = u.damageTaken.targets[casterGuid]
                if not s then
                    local sinfo = CL.GuidCache and CL.GuidCache.Resolve(casterGuid)
                    s = {
                        name = (sinfo and sinfo.name) or casterGuid,
                        total = 0, hits = 0, spells = {},
                        melee = NewMeleeEntry(), offhand = NewMeleeEntry(),
                        petMelee = NewMeleeEntry(), petOffhand = NewMeleeEntry(),
                    }
                    u.damageTaken.targets[casterGuid] = s
                end
                s.total = s.total + amount
                s.hits = s.hits + 1
                if spellId then
                    local entry = EnsureSpellEntry(s.spells, spellId, spellName, school)
                    RecordHit(entry, amount, isCrit)
                    RecordHit(EnsureSplitBucket(entry, isPeriodic and "tickHits" or "directHits"), amount, isCrit)
                else
                    RecordHit(MeleeEntryFor(s, false, isOffhand), amount, isCrit)
                end
            end
        end
    end
end

local function RecordDamage(casterGuid, targetGuid, spellId, spellName, school, amount, isCrit, isOffhand, isPeriodic)
    if not current then
        -- Self-inflicted damage (Bloodrage, etc.) is never enough on its
        -- own to lazy-start a session - it's not evidence any real
        -- encounter is happening, just a roster member (almost always
        -- the player) damaging themselves. See PLAYER_REGEN_DISABLED's
        -- comment in Events.lua for the full story - this event still
        -- gets recorded normally below if an encounter is ALREADY
        -- running, just never used to spin one up from nothing.
        if casterGuid and targetGuid and casterGuid == targetGuid then return end
        if not ShouldLazyStart(casterGuid, targetGuid) then return end
        StartEncounter()
    end

    -- Pull attribution: whoever's action is the first damage event
    -- against/from a boss-tagged enemy this encounter "pulled" it - set
    -- once. Stays nil (and keeps re-checking each call) until a
    -- boss-tagged hit actually happens, so a trash-only encounter never
    -- claims this and never prints - see CL.GetSetting("announcePulls").
    --
    -- Skipped entirely once BOTH isBossFight and pullBy are already
    -- settled - IsBossTaggedEnemy does a real UnitClassification pcall,
    -- not worth paying on every single damage event for the rest of a
    -- multi-minute boss fight once neither answer can change anymore
    -- (isBossFight only ever goes false->true; pullBy is "once ever").
    -- Kept as an OR (not just "not isBossFight") so the rare case of the
    -- very first boss-tagged hit having no resolvable casterGuid doesn't
    -- permanently strand pullBy at nil - later calls keep checking until
    -- a boss-tagged hit with a real caster shows up too. A boss that
    -- joins a fight already in progress (an add, a phase transition) is
    -- caught the same way, for the same reason.
    if not current.isBossFight or not current.pullBy then
        local isBossHit = IsBossTaggedEnemy(EnemyGuidFor(casterGuid, targetGuid))
        if isBossHit then
            current.isBossFight = true
            if not current.pullBy and casterGuid then
                local info = CL.GuidCache and CL.GuidCache.Resolve(casterGuid)
                current.pullBy = { name = (info and info.name) or casterGuid, label = spellName or "Auto Attack" }
                if CL.GetSetting("announcePulls") ~= false then
                    CL.Print("Pull: " .. current.pullBy.name .. " (" .. current.pullBy.label .. ")")
                end
            end
        end
    end

    RecordDamageInto(current.units, casterGuid, targetGuid, spellId, spellName, school, amount, isCrit, isOffhand, isPeriodic)
    RecordDamageInto(overall.units, casterGuid, targetGuid, spellId, spellName, school, amount, isCrit, isOffhand, isPeriodic)

    if casterGuid and IsTrackedGuid(AttributedGuid(casterGuid)) then
        RecordSeriesPoint(current, "damage", amount)
        if current.isBossFight then
            local abilityKey = spellId or (isOffhand and OFFHAND_ABILITY_KEY or MELEE_ABILITY_KEY)
            local abilityName = spellName or (isOffhand and "Off-Hand" or "Auto Attack")
            RecordAbilitySeriesPoint(current, abilityKey, abilityName, amount)
        end
    end
    if targetGuid and IsTrackedGuid(AttributedGuid(targetGuid)) then
        RecordSeriesPoint(current, "taken", amount)
    end

    -- Tally damage dealt to whatever's NOT a roster member - i.e. the
    -- mob(s) actually being fought - purely so History.lua can label a
    -- saved encounter by the toughest thing in the pull. Mobs otherwise
    -- never get a units entry at all (see RecordDamageInto above).
    if casterGuid and targetGuid and IsTrackedGuid(AttributedGuid(casterGuid)) then
        local targetAttributed = AttributedGuid(targetGuid)
        if not IsTrackedGuid(targetAttributed) then
            current.mobTally[targetAttributed] = (current.mobTally[targetAttributed] or 0) + amount

            -- This client's SuperWoW lets a raw GUID stand in for a unit
            -- token directly (see GuidCache.lua) - UnitHealthMax(guid)
            -- resolves right here with no "target"/nameplate token
            -- needed, as long as the mob is actually in range, which it
            -- is by definition (we just recorded a hit on it). Keep the
            -- highest sample seen, not the latest - a mob fought down to
            -- a sliver shouldn't end up looking small.
            if UnitHealthMax then
                local ok, maxHp = pcall(UnitHealthMax, targetAttributed)
                if ok and maxHp and maxHp > (current.mobHealth[targetAttributed] or 0) then
                    current.mobHealth[targetAttributed] = maxHp
                end
            end
        end
    end

    if targetGuid then
        local attributedTarget = AttributedGuid(targetGuid)
        if IsTrackedGuid(attributedTarget) then
            local attackerName = "Environment"
            if casterGuid then
                local info = CL.GuidCache and CL.GuidCache.Resolve(casterGuid)
                attackerName = (info and info.name) or casterGuid
            end
            local label = spellName
            if not label then
                local isPet = (attributedTarget ~= targetGuid)
                if isPet then
                    label = isOffhand and "Pet Off-Hand" or "Pet Auto Attack"
                else
                    label = isOffhand and "Off-Hand" or "Auto Attack"
                end
            end
            RecordRecapHit(attributedTarget, attackerName, label, amount, isCrit)
        end
    end
end

-- "Casts" for a DoT (Corruption, Curse of Agony) is a genuinely
-- different number than its tick count - one cast produces several
-- ticks over the debuff's duration - so it needs its own signal instead
-- of reusing entry.hits (see Events.lua's HandleAuraCast). Only ever
-- attributed to the top-level unit entry (u.damageDone.spells), not
-- per-target sub-entries - "Casts" is shown on the unit-wide breakdown
-- panel, not the per-target one.
local function RecordCastInto(units, casterGuid, spellId, spellName)
    if not casterGuid or not spellId then return end
    local attributed = AttributedGuid(casterGuid)
    if not IsTrackedGuid(attributed) then return end
    local u = EnsureUnit(units, attributed)
    local entry = u.damageDone.spells[spellId]
    if entry then
        entry.casts = (entry.casts or 0) + 1
    else
        -- No damage entry yet (the cast fires before the first tick
        -- lands) - stash the count on the unit itself, NOT as a spell
        -- entry, so a spell that never actually deals damage (an
        -- ordinary self-buff cast, also seen on AURA_CAST) never shows
        -- up as a stray zero-damage row in Damage Done. RecordDamageInto
        -- folds this in once a real entry is created.
        u.pendingCasts = u.pendingCasts or {}
        u.pendingCasts[spellId] = (u.pendingCasts[spellId] or 0) + 1
    end
end

local function RecordCast(casterGuid, spellId, spellName)
    -- Deliberately does NOT lazy-start like RecordDamage/RecordHealing/
    -- etc. do - AURA_CAST fires for every buff/heal cast on a tracked
    -- unit, not just combat spells (confirmed via debug log: a priest's
    -- routine post-fight Renew, cast well outside ShouldLazyStart's
    -- 3-second phantom-guard window, was enough to spin up a blank
    -- encounter and wipe the just-finished Current Fight). A cast alone
    -- is never real evidence combat resumed, so if there's no already-
    -- active encounter to tally into, just drop it - the very first
    -- cast of a fight-opening DoT can undercount by one (falls back to
    -- matching the tick count in the breakdown window), which is a far
    -- smaller cost than phantom-restarting on unrelated healing.
    if not current then return end
    RecordCastInto(current.units, casterGuid, spellId, spellName)
    RecordCastInto(overall.units, casterGuid, spellId, spellName)
end

local VICTIMSTATE_KEY = {
    [CL.VICTIMSTATE_MISS] = "miss",
    [CL.VICTIMSTATE_DODGE] = "dodge",
    [CL.VICTIMSTATE_PARRY] = "parry",
    [CL.VICTIMSTATE_BLOCK] = "block",
    [CL.VICTIMSTATE_EVADE] = "evade",
    [CL.VICTIMSTATE_IMMUNE] = "immune",
    [CL.VICTIMSTATE_DEFLECT] = "deflect",
}

local function RecordAvoidanceInto(units, casterGuid, targetGuid, key, isOffhand)
    if casterGuid then
        local attributed = AttributedGuid(casterGuid)
        if IsTrackedGuid(attributed) then
            local u = EnsureUnit(units, attributed)
            local entry = MeleeEntryFor(u.damageDone, attributed ~= casterGuid, isOffhand)
            entry.avoided[key] = entry.avoided[key] + 1
        end
    end
    if targetGuid then
        local attributed = AttributedGuid(targetGuid)
        if IsTrackedGuid(attributed) then
            local u = EnsureUnit(units, attributed)
            local entry = MeleeEntryFor(u.damageTaken, attributed ~= targetGuid, isOffhand)
            entry.avoided[key] = entry.avoided[key] + 1
        end
    end
end

-- A melee swing that connected for 0 damage because it was avoided -
-- see AUTO_ATTACK's victimState in Events.lua's HandleAutoAttack. Not
-- routed through RecordDamage since amount is always 0 here; still
-- writes into both current and overall like every other Record* call.
local function RecordAvoidance(casterGuid, targetGuid, victimState, isOffhand)
    if not current then
        if not ShouldLazyStart(casterGuid, targetGuid) then return end
        StartEncounter()
    end
    local key = VICTIMSTATE_KEY[victimState] or "other"
    RecordAvoidanceInto(current.units, casterGuid, targetGuid, key, isOffhand)
    RecordAvoidanceInto(overall.units, casterGuid, targetGuid, key, isOffhand)
end

local function RecordHealingInto(units, casterGuid, targetGuid, spellId, spellName, amount, overheal, isCrit)
    if not casterGuid then return end
    local attributed = AttributedGuid(casterGuid)
    if not IsTrackedGuid(attributed) then return end
    local u = EnsureUnit(units, attributed)
    u.healingDone.total = u.healingDone.total + amount
    u.healingDone.overheal = u.healingDone.overheal + (overheal or 0)
    RecordHit(EnsureSpellEntry(u.healingDone.spells, spellId, spellName, nil), amount, isCrit)

    if targetGuid then
        local t = u.healingDone.targets[targetGuid]
        if not t then
            local tinfo = CL.GuidCache and CL.GuidCache.Resolve(targetGuid)
            t = { name = (tinfo and tinfo.name) or targetGuid, total = 0, hits = 0, overheal = 0, spells = {} }
            u.healingDone.targets[targetGuid] = t
        end
        t.total = t.total + amount
        t.hits = t.hits + 1
        t.overheal = t.overheal + (overheal or 0)
        RecordHit(EnsureSpellEntry(t.spells, spellId, spellName, nil), amount, isCrit)
    end
end

local function RecordHealing(casterGuid, targetGuid, spellId, spellName, amount, overheal, isCrit)
    -- Does NOT lazy-start - see RecordCast's comment. Confirmed via
    -- debug log: a priest's routine post-fight Renew tick, healing the
    -- raid back up long after ShouldLazyStart's 3-second phantom-guard
    -- window had already elapsed, phantom-started a blank encounter and
    -- wiped the just-finished Current Fight. Healing happens constantly
    -- outside of combat (topping off between pulls) - not valid
    -- evidence a fight resumed.
    if not current then return end
    RecordHealingInto(current.units, casterGuid, targetGuid, spellId, spellName, amount, overheal, isCrit)
    RecordHealingInto(overall.units, casterGuid, targetGuid, spellId, spellName, amount, overheal, isCrit)

    if casterGuid and IsTrackedGuid(AttributedGuid(casterGuid)) then
        RecordSeriesPoint(current, "healing", amount)
    end
end

-- Shared by Cleanses/Buffs Given/Debuffs Given - all three are "how many
-- times did X happen" counts (amount always 1, no "how much" the way
-- damage/healing have), same bucket shape (spells/targets), so this one
-- function backs all three instead of three near-identical copies.
-- `bucketKey` picks which field on the unit record to write into
-- ("cleanses" / "buffsGiven" / "debuffsGiven").
local function RecordCountEventInto(units, bucketKey, casterGuid, targetGuid, spellId, spellName)
    if not casterGuid then return end
    local attributed = AttributedGuid(casterGuid)
    if not IsTrackedGuid(attributed) then return end
    local u = EnsureUnit(units, attributed)
    local bucket = u[bucketKey]
    bucket.total = bucket.total + 1
    RecordHit(EnsureSpellEntry(bucket.spells, spellId, spellName, nil), 1, false)

    if targetGuid then
        local t = bucket.targets[targetGuid]
        if not t then
            local tinfo = CL.GuidCache and CL.GuidCache.Resolve(targetGuid)
            t = { name = (tinfo and tinfo.name) or targetGuid, total = 0, hits = 0, spells = {} }
            bucket.targets[targetGuid] = t
        end
        t.total = t.total + 1
        t.hits = t.hits + 1
        RecordHit(EnsureSpellEntry(t.spells, spellId, spellName, nil), 1, false)
    end
end

local function RecordCleanse(casterGuid, targetGuid, spellId, spellName)
    -- Does NOT lazy-start - see RecordCast's comment. Dispelling a
    -- poison/curse/disease off a party member routinely happens outside
    -- of combat too, so it's not valid evidence a fight resumed.
    if not current then return end
    RecordCountEventInto(current.units, "cleanses", casterGuid, targetGuid, spellId, spellName)
    RecordCountEventInto(overall.units, "cleanses", casterGuid, targetGuid, spellId, spellName)
end

local function RecordDebuffGiven(casterGuid, targetGuid, spellId, spellName)
    if not current then
        if not ShouldLazyStart(casterGuid, targetGuid) then return end
        StartEncounter()
    end
    RecordCountEventInto(current.units, "debuffsGiven", casterGuid, targetGuid, spellId, spellName)
    RecordCountEventInto(overall.units, "debuffsGiven", casterGuid, targetGuid, spellId, spellName)
end

local function RecordInterrupt(casterGuid, targetGuid, spellId, spellName)
    if not current then
        if not ShouldLazyStart(casterGuid, targetGuid) then return end
        StartEncounter()
    end
    RecordCountEventInto(current.units, "interrupts", casterGuid, targetGuid, spellId, spellName)
    RecordCountEventInto(overall.units, "interrupts", casterGuid, targetGuid, spellId, spellName)
end

local function RecordDeath(guid)
    local attributed = AttributedGuid(guid)
    -- Pet deaths deliberately don't roll up to the owner here, unlike
    -- damage/healing - a Warlock's Voidwalker dying is not the same as
    -- the Warlock dying, and Deaths is a real UI category people will
    -- look at directly.
    if attributed ~= guid then return nil end
    if not IsTrackedGuid(attributed) then return nil end
    local u = EnsureUnit(overall.units, attributed)
    u.deaths = u.deaths + 1
    if current then
        local uc = EnsureUnit(current.units, attributed)
        uc.deaths = uc.deaths + 1
    end
    SnapshotDeathRecap(attributed)
    return attributed
end

--------------------------------------------------------------------------
-- Test mode - fabricated encounter for previewing appearance settings
-- (bar texture/font/size/color) without needing to actually fight
-- something, same idea as Details' "Create test bars" button. Built
-- from the same NewEncounter/EnsureUnit/RecordHit helpers real combat
-- events use, so it's genuinely the same shape - the breakdown window's
-- click-through works on it same as a real encounter.
--------------------------------------------------------------------------

local testEncounter = nil -- cached once generated, not regenerated every refresh

-- amount/hits/crit% all scale off `power` (1.0 = top of the pack) so
-- whichever unit is called with power=1 always sorts first in every
-- mode, regardless of what real numbers would make sense per-class.
local function FakeHits(bucket, entry, count, avgAmount, critPct)
    local i
    for i = 1, count do
        local isCrit = (math.random(100) <= critPct)
        local amount = math.floor(avgAmount * (0.8 + math.random() * 0.4))
        if isCrit then amount = math.floor(amount * 1.8) end
        RecordHit(entry, amount, isCrit)
        bucket.total = bucket.total + amount
    end
end

local TEST_SPELLS_WARLOCK = { { id = 172, name = "Corruption", school = "Shadow" }, { id = 686, name = "Shadow Bolt", school = "Shadow" } }
local TEST_SPELLS_GENERIC = { { id = 133, name = "Fireball", school = "Fire" }, { id = 585, name = "Smite", school = "Holy" } }

local function FakeDamageDone(u, power)
    local bucket = u.damageDone
    FakeHits(bucket, bucket.melee, math.floor(18 * power) + 4, 220 * power, 18)
    local spellList = (u.classToken == "WARLOCK") and TEST_SPELLS_WARLOCK or TEST_SPELLS_GENERIC
    local i
    for i = 1, table.getn(spellList) do
        local sp = spellList[i]
        local entry = EnsureSpellEntry(bucket.spells, sp.id, sp.name, sp.school)
        FakeHits(bucket, entry, math.floor(10 * power) + 2, 350 * power, 22)
    end

    -- Two fake targets so the breakdown window's Targets: list (and the
    -- "All Enemies" reset row) has something to show too.
    local bossTotal = math.floor(bucket.total * 0.7)
    bucket.targets["TESTBOSS"] = { name = "Training Dummy", total = bossTotal, hits = math.floor((bucket.melee.hits or 0) * 0.7), spells = {}, melee = NewMeleeEntry(), offhand = NewMeleeEntry(), petMelee = NewMeleeEntry(), petOffhand = NewMeleeEntry() }
    bucket.targets["TESTADD1"] = { name = "Training Dummy's Friend", total = bucket.total - bossTotal, hits = math.floor((bucket.melee.hits or 0) * 0.3), spells = {}, melee = NewMeleeEntry(), offhand = NewMeleeEntry(), petMelee = NewMeleeEntry(), petOffhand = NewMeleeEntry() }
end

local function FakeHealingDone(u, power)
    local bucket = u.healingDone
    local entry = EnsureSpellEntry(bucket.spells, 2050, "Lesser Heal", "Holy")
    local i
    for i = 1, math.floor(12 * power) + 2 do
        local isCrit = (math.random(100) <= 15)
        local amount = math.floor(300 * power * (0.8 + math.random() * 0.4))
        if isCrit then amount = math.floor(amount * 1.5) end
        RecordHit(entry, amount, isCrit)
        bucket.total = bucket.total + amount
        bucket.overheal = bucket.overheal + math.floor(amount * 0.15)
    end

    -- Two fake recipients so the breakdown window's "Healed:" list has
    -- something to show too.
    local tankTotal = math.floor(bucket.total * 0.6)
    bucket.targets["TESTTANK"] = { name = "Kaladin", total = tankTotal, hits = math.floor(entry.hits * 0.6), overheal = 0, spells = {} }
    bucket.targets["TESTSELF"] = { name = u.name, total = bucket.total - tankTotal, hits = entry.hits - math.floor(entry.hits * 0.6), overheal = 0, spells = {} }
end

local function FakeDamageTaken(u, power)
    local bucket = u.damageTaken
    FakeHits(bucket, bucket.melee, math.floor(8 * power) + 3, 150 * power, 10)

    -- One fake attacker so the breakdown window's "Attackers:" list has
    -- something to show too.
    bucket.targets["TESTBOSS"] = { name = "Training Dummy", total = bucket.total, hits = bucket.melee.hits, spells = {}, melee = NewMeleeEntry(), offhand = NewMeleeEntry(), petMelee = NewMeleeEntry(), petOffhand = NewMeleeEntry() }
end

-- Shared by FakeCleanses/FakeDebuffsGiven - fills one count-only bucket
-- with `count` hits of a single fake ability and one fake recipient,
-- same shape RecordCountEventInto produces for real.
local function FakeCountEvent(bucket, spellId, spellName, count, recipientGuid, recipientName)
    local entry = EnsureSpellEntry(bucket.spells, spellId, spellName, nil)
    local i
    for i = 1, count do
        RecordHit(entry, 1, false)
        bucket.total = bucket.total + 1
    end
    if count > 0 then
        bucket.targets[recipientGuid] = { name = recipientName, total = count, hits = count, spells = {} }
    end
end

local function FakeCleanses(u, power)
    FakeCountEvent(u.cleanses, 4987, "Cleanse", math.floor(3 * power), "TESTTANK", "Kaladin")
end

local function FakeDebuffsGiven(u, power)
    FakeCountEvent(u.debuffsGiven, 172, "Corruption", math.floor(4 * power), "TESTBOSS", "Training Dummy")
end

local function FakeInterrupts(u, power)
    FakeCountEvent(u.interrupts, 1766, "Kick", math.floor(2 * power), "TESTBOSS", "Training Dummy")
end

-- name, classToken, power (1.0 = always tops every mode - "Kobeni the
-- Warlock" is the player's own character, shown first by design). The
-- rest of the roster is Stormlight Archive characters, cast against
-- the classes they fit best.
local TEST_ROSTER = {
    { name = "Kobeni", classToken = "WARLOCK", power = 1.0, isPlayer = true },
    { name = "Kaladin", classToken = "WARRIOR", power = 0.92 },
    { name = "Szeth", classToken = "ROGUE", power = 0.88 },
    { name = "Dalinar", classToken = "PALADIN", power = 0.85 },
    { name = "Shallan", classToken = "MAGE", power = 0.75 },
    { name = "Jasnah", classToken = "PRIEST", power = 0.7 },
    { name = "Adolin", classToken = "WARRIOR", power = 0.65 },
    { name = "Teft", classToken = "HUNTER", power = 0.6 },
    { name = "Renarin", classToken = "DRUID", power = 0.55 },
    { name = "Navani", classToken = "SHAMAN", power = 0.5 },
}

-- Builds the unit record directly rather than going through EnsureUnit -
-- that calls into GuidCache.Resolve, which expects a real combat GUID
-- and (on this client) hard-errors on an arbitrary string like
-- "TESTUNIT1" instead of just returning nil.
local function NewTestUnit(r)
    return {
        name = r.name,
        class = r.classToken,
        classToken = r.classToken,
        isPlayer = r.isPlayer,
        damageDone = NewBucket(),
        healingDone = { total = 0, overheal = 0, spells = {}, targets = {} },
        damageTaken = NewBucket(),
        cleanses = { total = 0, spells = {}, targets = {} },
        debuffsGiven = { total = 0, spells = {}, targets = {} },
        interrupts = { total = 0, spells = {}, targets = {} },
        deaths = 0,
    }
end

local function GenerateTestEncounter()
    local enc = NewEncounter()
    enc.label = "Test Data"
    enc.duration = 60
    local i
    for i = 1, table.getn(TEST_ROSTER) do
        local r = TEST_ROSTER[i]
        local guid = "TESTUNIT" .. i
        local u = NewTestUnit(r)
        enc.units[guid] = u
        FakeDamageDone(u, r.power)
        FakeHealingDone(u, r.power)
        FakeDamageTaken(u, r.power)
        FakeCleanses(u, r.power)
        FakeDebuffsGiven(u, r.power)
        FakeInterrupts(u, r.power)
    end
    enc.units["TESTUNIT7"].deaths = 1 -- Adolin - one fake death, for previewing Deaths mode
    return enc
end

local function GetTestEncounter()
    if not testEncounter then
        testEncounter = GenerateTestEncounter()
    end
    return testEncounter
end

local function ClearTestEncounter()
    testEncounter = nil
end

CL.Aggregator = {
    SERIES_BUCKET_SECONDS = TIMELINE_BUCKET_SECONDS,
    ABILITY_BUCKET_SECONDS = ABILITY_BUCKET_SECONDS,
    StartEncounter = StartEncounter,
    EndEncounter = EndEncounter,
    GetCurrent = GetCurrent,
    GetCurrentDisplay = GetCurrentDisplay,
    GetOverall = GetOverall,
    GetOverallDuration = GetOverallDuration,
    ResetOverall = ResetOverall,
    GetDeathRecap = GetDeathRecap,
    SnapshotDeathRecap = SnapshotDeathRecap, -- exposed for /cl testdeath - doesn't touch the real death counter
    RecordDamage = RecordDamage,
    RecordAvoidance = RecordAvoidance,
    RecordHealing = RecordHealing,
    RecordCast = RecordCast,
    RecordCleanse = RecordCleanse,
    RecordDebuffGiven = RecordDebuffGiven,
    RecordInterrupt = RecordInterrupt,
    RecordDeath = RecordDeath,
    GetTestEncounter = GetTestEncounter,
    ClearTestEncounter = ClearTestEncounter,
    SerializeState = SerializeState,
    RestoreState = RestoreState,
}
