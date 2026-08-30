--[[
    Events - enables the Nampower CVars the combat events are gated
    behind (default off), registers them, and dispatches into the
    Aggregator. With CL.debug on, every raw event logs its full argument
    list to CL.LOG_FILENAME (via CL.LogLine/FlushLog in Core.lua). Chat
    stays quiet (just load/encounter start-stop) since real combat event
    volume would make chat unreadable.
]]

local CL = CombatLedger

local cvarsToEnable = {
    "NP_EnableAutoAttackEvents",
    "NP_EnableSpellStartEvents",
    "NP_EnableSpellGoEvents",
    "NP_EnableSpellHealEvents",
    "NP_EnableSpellEnergizeEvents",
    -- SPELL_DISPEL_BY_SELF/OTHER needs no CVar per Nampower's changelog.
    -- AURA_CAST_ON_SELF/OTHER is needed for the debuffs-given correlation
    -- (see HandleAuraCast/HandleDebuffAdded below). BUFF/DEBUFF_ADDED_*
    -- need no CVar per Nampower's changelog.
    "NP_EnableAuraCastEvents",
}
local function EnableCVars()
    local i
    for i = 1, table.getn(cvarsToEnable) do
        pcall(SetCVar, cvarsToEnable[i], "1")
    end
end

-- Best-effort spell name lookup for the breakdown UI - wrapped since
-- GetSpellRecField's behavior isn't guaranteed for every spellId, and a
-- failure here shouldn't break event handling.
local function SpellName(spellId)
    if not spellId or not GetSpellRecField then return nil end
    local ok, name = pcall(GetSpellRecField, spellId, "name")
    if ok then return name end
    return nil
end

-- Nampower's *_OTHER events aren't scoped to your group - without this,
-- a random unrelated player fighting a different mob nearby would get
-- recorded as if they were part of the fight. Only record when at least
-- one side is player/party/raid/pet (see GuidCache's roster tracking);
-- the other side is free to be any mob/player, so "you hit a mob" and
-- "a mob hits you" both pass, but "stranger hits unrelated mob" doesn't.
local function IsRelevant(guidA, guidB)
    if not CL.GuidCache then return false end
    return CL.GuidCache.IsTracked(guidA) or CL.GuidCache.IsTracked(guidB)
end

-- Declared here (not down near FinishEncounter, where the idle-trim
-- logic that reads lastEventTime lives) so the Handle* functions below
-- can call it - Lua resolves an identifier at compile time based on
-- what's lexically in scope ABOVE it in the file, so a local declared
-- later is invisible to code above it and would silently resolve to a
-- nonexistent global instead.
local lastEventTime = 0
local function TouchActivity()
    lastEventTime = GetTime()
end

local function HandleAutoAttack(isSelf, attackerGuid, targetGuid, totalDamage, hitInfo, victimState, componentCount, blocked, absorbed, resisted)
    totalDamage = tonumber(totalDamage) or 0
    hitInfo = tonumber(hitInfo)
    local relevant = IsRelevant(attackerGuid, targetGuid)
    -- Only touches activity for OUR OWN combat, not every hit anyone
    -- nearby lands - TouchActivity() used to be called unconditionally
    -- by the dispatcher before relevance was even known, so a busy area
    -- (other players fighting other things nearby) kept lastEventTime
    -- constantly fresh regardless of whether the PLAYER was still doing
    -- anything. That silently defeated both the idle-timeout fallback
    -- and EndEncounter's trailing-idle-time trim (see Aggregator.lua) -
    -- confirmed via debug log: dense [FILTERED] combat noise from other
    -- players kept a finished fight's reported duration inflated by
    -- however long that noise kept going after the real fight ended.
    if relevant then TouchActivity() end
    if CL.debug then
        CL.LogLine(string.format(
            "%s[AUTO_ATTACK_%s] atk=%s tgt=%s dmg=%d hitInfo=%s victimState=%s comp=%s blocked=%s absorbed=%s resisted=%s",
            relevant and "" or "[FILTERED] ", isSelf and "SELF" or "OTHER", tostring(attackerGuid), tostring(targetGuid), totalDamage,
            tostring(hitInfo), tostring(victimState), tostring(componentCount),
            tostring(blocked), tostring(absorbed), tostring(resisted)))
    end
    local isOffhand = CL.HasBit(hitInfo, CL.AUTO_ATTACK_HITFLAG_OFFHAND)
    if relevant and totalDamage > 0 then
        -- See Core.lua for bit meanings - glancing/crushing aren't
        -- tracked as their own stat; only crit feeds into isCrit.
        local isCrit = CL.HasBit(hitInfo, CL.AUTO_ATTACK_HITFLAG_CRIT)
        CL.Aggregator.RecordDamage(attackerGuid, targetGuid, nil, nil, nil, totalDamage, isCrit, isOffhand)
    elseif relevant and totalDamage == 0 then
        -- dmg=0 auto-attacks are avoided swings (dodge/parry/miss/etc,
        -- not "0 damage hits") - see Core.lua's VICTIMSTATE_* comment.
        -- Off-hand misses carry the same 0x04 bit (hitInfo=20 = 0x14 =
        -- miss|offhand).
        CL.Aggregator.RecordAvoidance(attackerGuid, targetGuid, tonumber(victimState), isOffhand)
    end
end

-- SPELL_DAMAGE_EVENT's last argument is "effect1,effect2,effect3,auraType"
-- per Nampower's EVENTS.md - the 4th field only present "if applicable".
-- auraType 3 (SPELL_AURA_PERIODIC_DAMAGE), 89
-- (SPELL_AURA_PERIODIC_DAMAGE_PERCENT), or 53 (SPELL_AURA_PERIODIC_LEECH -
-- Siphon Life's actual aura type, since it damages the target AND heals
-- the caster from one periodic tick), per vmangos-core's
-- SpellAuraDefines.h, means this specific damage instance was a DoT
-- tick, not the spell's initial hit - e.g. Rake/Immolate's opening
-- strike can crit, the bleed/burn ticks after it never can, and mixing
-- both into one min/max is exactly what read as "weird" reports.
-- There's no dedicated periodic flag (unlike SPELL_HEAL's periodicFlag
-- param below), so this is the only signal available - a full
-- comma-split (not just "whatever's after the last comma") is
-- necessary since a non-periodic hit's effect string only has 3 fields,
-- not 4, so its last field is a real effect number, not an aura type.
local PERIODIC_AURA_TYPES = { ["3"] = true, ["89"] = true, ["53"] = true }

-- Confirmed via debug log that some SPELL_AURA_PERIODIC_LEECH spells
-- (damage the target AND heal the caster off the same tick) never carry
-- an aura-type tail at all - Siphon Life's SPELL_DAMAGE_EVENT reports
-- effect=6,0,0,0 on every single tick, even though every hit IS a tick
-- (the spell has no separate upfront direct-hit component). Nampower/
-- vmangos just doesn't tag these, so effect-string parsing can't see
-- it - listed here as a known, confirmed exception. Add more spellIds
-- if another leech-style DoT (e.g. Drain Life) shows the same gap.
local ALWAYS_PERIODIC_SPELLS = {
    [18881] = true, -- Siphon Life
}

local function IsPeriodicEffect(effectStr, spellId)
    if ALWAYS_PERIODIC_SPELLS[spellId] then return true end
    if not effectStr or effectStr == "" then return false end
    local fields = {}
    local from = 1
    while true do
        local pos = string.find(effectStr, ",", from, true)
        if not pos then
            table.insert(fields, string.sub(effectStr, from))
            break
        end
        table.insert(fields, string.sub(effectStr, from, pos - 1))
        from = pos + 1
    end
    return PERIODIC_AURA_TYPES[fields[4]] == true
end

local function HandleSpellDamage(isSelf, targetGuid, casterGuid, spellId, amount, mitigation, hitInfo, school, effect)
    amount = tonumber(amount) or 0
    spellId = tonumber(spellId)
    hitInfo = tonumber(hitInfo)
    local name = SpellName(spellId)
    local relevant = IsRelevant(casterGuid, targetGuid)
    if relevant then TouchActivity() end -- see HandleAutoAttack's comment - relevance-gated, not blanket
    if CL.debug then
        CL.LogLine(string.format(
            "%s[SPELL_DAMAGE_EVENT_%s] tgt=%s caster=%s spell=%s(%s) dmg=%d mitigation=%s hitInfo=%s school=%s effect=%s",
            relevant and "" or "[FILTERED] ", isSelf and "SELF" or "OTHER", tostring(targetGuid), tostring(casterGuid),
            tostring(name), tostring(spellId), amount, tostring(mitigation), tostring(hitInfo), tostring(school), tostring(effect)))
    end
    if relevant and amount > 0 then
        local isCrit = CL.HasBit(hitInfo, CL.SPELL_DAMAGE_HITFLAG_CRIT)
        local isPeriodic = IsPeriodicEffect(effect, spellId)
        CL.Aggregator.RecordDamage(casterGuid, targetGuid, spellId, name, school, amount, isCrit, nil, isPeriodic)
    end
end

-- Taunts (Warrior Taunt/Challenging Shout, Druid Challenging Roar, and
-- this server's own custom tank-cooldown taunts - Paladin's Hand of
-- Reckoning, Shaman's Earthshaker Slam) generate no damage and no debuff
-- on the target in vanilla, so none of the events above ever see them
-- land - SPELL_GO is the only structured "this spell resolved" signal
-- available for a non-damaging ability (see Nampower's EVENTS.md:
-- itemId, spellId, casterGuid, targetGuid, castFlags, numHit,
-- numMissed). Only used for this right now; a real interrupt-detection
-- feature (Kick/Pummel/Counterspell landing) would also hang off this
-- same event, but that's a separate, not-yet-wired-up feature - see
-- Aggregator.lua's RecordInterrupt, which nothing currently calls.
--
-- Real vanilla Paladins have no taunt at all (Righteous Defense is a
-- TBC addition) - this server gives them Hand of Reckoning instead
-- (spellId 62124, from SuperCleveRoidMacros's own custom-spell data),
-- and Shaman an entirely custom tanking kit (Earthshaker Slam, spellId
-- 51365, "Requires Shields" - confirmed live via /cl debug + /cl flush,
-- caught by SPELL_GO_SELF).
local TAUNT_SPELL_IDS = {
    [355] = true,   -- Taunt
    [1161] = true,  -- Challenging Shout
    [5209] = true,  -- Challenging Roar
    [62124] = true, -- Hand of Reckoning (Paladin, this server's taunt)
    [51365] = true, -- Earthshaker Slam (Shaman, this server's taunt)
}

local function HandleSpellGo(isSelf, itemId, spellId, casterGuid, targetGuid, castFlags, numHit, numMissed)
    spellId = tonumber(spellId)
    numHit = tonumber(numHit) or 0
    if not TAUNT_SPELL_IDS[spellId] then return end
    if numHit <= 0 then return end -- fully resisted/immune - no threat effect happened
    if CL.debug then
        CL.LogLine(string.format("[SPELL_GO_%s] taunt spell=%s(%s) caster=%s tgt=%s numHit=%s",
            isSelf and "SELF" or "OTHER", tostring(SpellName(spellId)), tostring(spellId),
            tostring(casterGuid), tostring(targetGuid), tostring(numHit)))
    end
    if CL.Threat and CL.Threat.RecordTaunt then
        CL.Threat.RecordTaunt(casterGuid)
    end
end

local function HandleSpellHeal(targetGuid, casterGuid, spellId, amount, critFlag, periodicFlag)
    amount = tonumber(amount) or 0
    spellId = tonumber(spellId)
    local name = SpellName(spellId)
    local isCrit = (critFlag == "1" or critFlag == 1 or critFlag == true)
    local relevant = IsRelevant(casterGuid, targetGuid)
    if relevant then TouchActivity() end -- see HandleAutoAttack's comment - relevance-gated, not blanket
    if CL.debug then
        CL.LogLine(string.format(
            "%s[SPELL_HEAL] tgt=%s caster=%s spell=%s(%s) heal=%d crit=%s periodic=%s",
            relevant and "" or "[FILTERED] ", tostring(targetGuid), tostring(casterGuid), tostring(name), tostring(spellId),
            amount, tostring(critFlag), tostring(periodicFlag)))
    end
    if relevant and amount > 0 then
        CL.Aggregator.RecordHealing(casterGuid, targetGuid, spellId, name, amount, 0, isCrit)
    end
end

-- casterGuid, targetGuid, spellId - the spell that got dispelled, not
-- the dispel spell itself (so the breakdown window's per-ability list
-- shows "what did I cleanse", e.g. "Poison" x3, not just "Cleanse" x3).
local function HandleSpellDispel(casterGuid, targetGuid, spellId)
    spellId = tonumber(spellId)
    local name = SpellName(spellId)
    local relevant = IsRelevant(casterGuid, targetGuid)
    if relevant then TouchActivity() end -- see HandleAutoAttack's comment - relevance-gated, not blanket
    if CL.debug then
        CL.LogLine(string.format(
            "%s[SPELL_DISPEL] caster=%s tgt=%s spell=%s(%s)",
            relevant and "" or "[FILTERED] ", tostring(casterGuid), tostring(targetGuid), tostring(name), tostring(spellId)))
    end
    if relevant then
        CL.Aggregator.RecordCleanse(casterGuid, targetGuid, spellId, name)
    end
end

-- Debuffs given - two Nampower event families, each missing half of
-- what's needed, that fire on consecutive lines for the same cast:
--   AURA_CAST_ON_* - spellId, casterGuid, targetGuid, ... (caster, but
--                     no reliable buff/debuff classification)
--   DEBUFF_ADDED_* - guid, slot, spellId, ... (reliable classification -
--                     this event only fires for debuffs - but no caster)
-- AURA_CAST_ON_* stashes caster keyed by (targetGuid, spellId); the
-- following DEBUFF_ADDED_* looks that key up to get both pieces at
-- once. A single cast can fire AURA_CAST_ON_* more than once (multi-
-- effect auras like shapeshifts), which just overwrites the same key
-- harmlessly since the caster is identical each time.
--
-- BUFF_ADDED_* uses the same mechanism but is deliberately not wired to
-- anything - "Buffs Given" doesn't fit this addon's per-encounter model,
-- since prebuffing happens out of combat, before the encounter it's for
-- even starts (see Aggregator.lua). Not registering BUFF_ADDED_* at all,
-- so unmatched buff-side AURA_CAST entries just expire via the periodic
-- pendingAuraCasts sweep below instead of ever being looked up.
local pendingAuraCasts = {} -- key = targetGuid.."|"..spellId -> { casterGuid, time }
local PENDING_AURA_WINDOW = 2 -- seconds - generous margin since the two events fire on adjacent lines for the same cast

local function HandleAuraCast(spellId, casterGuid, targetGuid)
    spellId = tonumber(spellId)
    if not spellId or not targetGuid then return end
    if CL.debug then
        CL.LogLine(string.format("[AURA_CAST] caster=%s tgt=%s spell=%s(%s)",
            tostring(casterGuid), tostring(targetGuid), tostring(SpellName(spellId)), tostring(spellId)))
    end
    -- Only worth stashing if this could ever be relevant later (the
    -- target is what DEBUFF_ADDED_* will key off of, so caster
    -- relevance is checked again at that point too, but there's no
    -- reason to stash something neither side is tracked for).
    if not IsRelevant(casterGuid, targetGuid) then return end
    pendingAuraCasts[targetGuid .. "|" .. spellId] = { casterGuid = casterGuid, time = GetTime() }

    -- "Casts" count for the breakdown window (see UI_BreakdownWindow.lua)
    -- - fires once per actual cast, unlike a DoT's damage entry which
    -- fires once per tick. RecordCast no-ops internally for a caster
    -- that isn't actually tracked, and for a spell that never ends up
    -- dealing damage it just sits as an unread pending count - safe to
    -- call unconditionally here.
    CL.Aggregator.RecordCast(casterGuid, spellId, SpellName(spellId))
end

local function HandleDebuffAdded(guid, spellId)
    spellId = tonumber(spellId)
    if not spellId or not guid then return end
    local key = guid .. "|" .. spellId
    local pending = pendingAuraCasts[key]
    if CL.debug then
        CL.LogLine(string.format("[AURA_ADDED] DEBUFF guid=%s spell=%s(%s) matched=%s",
            tostring(guid), tostring(SpellName(spellId)), tostring(spellId), tostring(pending ~= nil)))
    end
    if not pending then return end
    pendingAuraCasts[key] = nil
    if (GetTime() - pending.time) > PENDING_AURA_WINDOW then return end
    if not IsRelevant(pending.casterGuid, guid) then return end
    CL.Aggregator.RecordDebuffGiven(pending.casterGuid, guid, spellId, SpellName(spellId))
end

-- SPELL_MISS/ENVIRONMENTAL_DMG/SPELL_ENERGIZE exist in Nampower per its
-- changelog, but their exact argument order isn't documented (unlike
-- AUTO_ATTACK/SPELL_DAMAGE_EVENT/SPELL_HEAL). Log every raw arg instead
-- of guessing at a Handle*-style signature - baking in a wrong
-- interpretation would be worse than not parsing these at all.
-- (DAMAGE_SHIELD's shape WAS deciphered this way, from real debug-log
-- data - see HandleDamageShield below.)
local function LogRawEvent(tag)
    if not CL.debug then return end
    CL.LogLine(string.format("[RAW %s] a1=%s a2=%s a3=%s a4=%s a5=%s a6=%s a7=%s a8=%s a9=%s",
        tag, tostring(arg1), tostring(arg2), tostring(arg3), tostring(arg4),
        tostring(arg5), tostring(arg6), tostring(arg7), tostring(arg8), tostring(arg9)))
end

-- DAMAGE_SHIELD_SELF/OTHER - vanilla's own dedicated "damage shield"
-- reflect event (Thorns, Retribution Aura, Vengeance, etc.), confirmed
-- via debug log: a1=caster (the unit wearing the reflect buff, dealing
-- this damage), a2=target (whoever struck them), a3=amount, a4=school.
-- This is a genuinely separate Nampower signal from SPELL_DAMAGE_EVENT
-- - no ambiguity about which real ability it was, unlike trying to
-- infer a reflect proc from a shared spellId. Matches how GreedMeter
-- itself identifies reflect damage too (vanilla's own DAMAGESHIELD
-- combat log text, a similarly dedicated signal, just read via chat
-- parsing instead of this Nampower event). No real spellId comes with
-- it, so REFLECT_SPELL_ID is a fixed synthetic id used only for this
-- bucket, named "Reflect" to match GreedMeter's own label.
local REFLECT_SPELL_ID = -1

local function HandleDamageShield(isSelf, casterGuid, targetGuid, amount, school)
    amount = tonumber(amount) or 0
    school = tonumber(school)
    local relevant = IsRelevant(casterGuid, targetGuid)
    if relevant then TouchActivity() end
    if CL.debug then
        CL.LogLine(string.format(
            "%s[DAMAGE_SHIELD_%s] caster=%s tgt=%s dmg=%d school=%s",
            relevant and "" or "[FILTERED] ", isSelf and "SELF" or "OTHER",
            tostring(casterGuid), tostring(targetGuid), amount, tostring(school)))
    end
    if relevant and amount > 0 then
        CL.Aggregator.RecordDamage(casterGuid, targetGuid, REFLECT_SPELL_ID, "Reflect", school, amount, false, nil, false)
    end
end

local autoShownMainWindow = false -- see the PLAYER_ENTERING_WORLD handler below

-- Some targets (training dummies, on at least this server) never toggle
-- PLAYER_REGEN_DISABLED/ENABLED at all, so an encounter against one
-- would otherwise never end. This is the fallback for that specific
-- case: no combat event of any kind for CL.IDLE_SECONDS force-ends the
-- encounter regardless of the regen flag. Everything else about when an
-- encounter ends is regen state alone - PLAYER_REGEN_ENABLED below ends
-- it immediately, always, no tolerance window, no group check. One
-- continuous engagement (any number of mobs, chained or simultaneous)
-- is one encounter as long as combat never actually drops; the moment
-- it does, that encounter is over, full stop - the next
-- PLAYER_REGEN_DISABLED always starts a new one, never resumes the old
-- one.
--
-- A group-wait (defer finishing until every raid/party member's own
-- combat flag also clears) used to live here, added after debug
-- logging caught a real instance of the player's own regen clearing
-- while 4 raid members were still UnitAffectingCombat()-true. Removed
-- again - GreedMeter (this addon's own reference point) has no such
-- check at all and reportedly never fragments a pull in months of real
-- use, so the theoretical risk isn't worth the stop feeling delayed on
-- every single fight to guard against an edge case that doesn't
-- actually bite in practice.
local function IsGrouped()
    return ((GetNumRaidMembers and GetNumRaidMembers()) or 0) > 0
        or ((GetNumPartyMembers and GetNumPartyMembers()) or 0) > 0
end

-- Tracked across PARTY_MEMBERS_CHANGED/RAID_ROSTER_UPDATE so "Clear on
-- join party" (Options) can fire only on the actual solo -> grouped
-- transition, not on every roster change while already grouped (someone
-- else joining/leaving a raid you're already in shouldn't wipe Overall).
local wasGrouped = IsGrouped()

-- Checks whether anyone else in the group is still flagged in combat.
-- On this client, GetNumPartyMembers() has been observed nonzero AT THE
-- SAME TIME as GetNumRaidMembers() while genuinely in a raid (a real
-- quirk, seen in the diagnostic log) - so this checks BOTH ranges
-- whenever they're nonzero rather than assuming they're mutually
-- exclusive, to avoid missing raid members if partyN is stale.
local function AnyGroupMemberInCombat()
    local raidN = (GetNumRaidMembers and GetNumRaidMembers()) or 0
    local partyN = (GetNumPartyMembers and GetNumPartyMembers()) or 0
    local i
    if raidN > 0 then
        for i = 1, raidN do
            local ok, inCombat = pcall(UnitAffectingCombat, "raid" .. i)
            if ok and inCombat then return true end
        end
    end
    if partyN > 0 then
        for i = 1, partyN do
            local ok, inCombat = pcall(UnitAffectingCombat, "party" .. i)
            if ok and inCombat then return true end
        end
    end
    return false
end

local function FinishEncounter()
    -- lastEventTime (touched by every relevant combat event - see
    -- TouchActivity above) trims trailing idle time out of the reported
    -- duration, matching GreedMeter's own Parser:OnCombatEnd - see
    -- Aggregator.lua's EndEncounter for why.
    local finished = CL.Aggregator.EndEncounter(lastEventTime)
    if not finished then return end

    -- Skip saving near-nothing encounters (a stray hit that barely
    -- registered before the idle timeout) - not worth a history slot.
    -- Boss fights (see Aggregator's isBossFight) go into their own
    -- per-boss-name bucket instead of the regular capped list, so they
    -- can't get pushed out by a busy trash-clearing session - see
    -- History.lua's SaveBossEncounter.
    if finished.duration > 1 and CL.TableCount(finished.units) > 0 and CL.History then
        if finished.isBossFight and CL.History.SaveBossEncounter then
            CL.History.SaveBossEncounter(finished)
        else
            CL.History.SaveEncounter(finished)
        end
    end

    -- FinishEncounter also fires from the idle-timeout fallback (no
    -- combat events for a while, not necessarily actually out of combat
    -- - a slow-starting fight can trip this while regen is still
    -- disabled). Only auto-hide when genuinely out of combat, or the
    -- window can hide itself mid-fight with nothing left to re-show it
    -- until the next real PLAYER_REGEN_DISABLED.
    if CL.UI and CL.UI.ApplyAutoHide and not UnitAffectingCombat("player") then
        CL.UI.ApplyAutoHide()
    end

    if CL.debug then
        CL.Print(string.format("Encounter ended: %.1fs, %d unit(s) tracked.",
            finished.duration, CL.TableCount(finished.units)))
        CL.LogLine(string.format("[REGEN] FinishEncounter: %.1fs, %d unit(s) tracked.",
            finished.duration, CL.TableCount(finished.units)))
        CL.FlushLog()
    end
end

-- Debug-only diagnostic for both regen events, ahead of whatever fix
-- comes next - logs enough to actually see the real event timeline
-- (with /cl debug on) instead of guessing at one again. Counts raid/
-- party members currently showing UnitAffectingCombat so it's possible
-- to tell, after the fact, whether the group was genuinely still
-- fighting when regen cleared for the player.
local function LogRegenDiagnostic(evt)
    if not CL.debug then return end
    local okP, playerCombat = pcall(UnitAffectingCombat, "player")
    local raidN = (GetNumRaidMembers and GetNumRaidMembers()) or 0
    local partyN = (GetNumPartyMembers and GetNumPartyMembers()) or 0
    local othersInCombat = 0
    local i
    if raidN > 0 then
        for i = 1, raidN do
            local ok, inCombat = pcall(UnitAffectingCombat, "raid" .. i)
            if ok and inCombat then othersInCombat = othersInCombat + 1 end
        end
    elseif partyN > 0 then
        for i = 1, partyN do
            local ok, inCombat = pcall(UnitAffectingCombat, "party" .. i)
            if ok and inCombat then othersInCombat = othersInCombat + 1 end
        end
    end
    CL.LogLine(string.format("[REGEN] %s t=%.1f playerCombat=%s raidN=%d partyN=%d membersInCombat=%d",
        evt, GetTime(), tostring(okP and playerCombat), raidN, partyN, othersInCombat))
end

local f = CreateFrame("Frame")

f:SetScript("OnEvent", function()
    if event == "PLAYER_ENTERING_WORLD" then
        EnableCVars()
        CL.GuidCache.Purge()
        CL.GuidCache.RefreshRoster()
        -- Deferred here (not called at UI_MainWindow.lua's file-load
        -- time) so the saved size/position is actually there to restore
        -- by the time the window shows - see that file's own comment.
        -- Once per session only, not every zone/loading screen.
        if not autoShownMainWindow then
            autoShownMainWindow = true
            -- Restore current/overall before the window's first Show()
            -- so it renders with the real data immediately, not a blank
            -- state that then jumps. If a live fight got restored,
            -- treat "just reloaded" as activity so the normal idle
            -- timeout can close it out shortly if nothing follows,
            -- rather than it sitting there indefinitely un-timed-out.
            CL.Aggregator.RestoreState(CombatLedgerDB.liveState)
            if CL.Aggregator.GetCurrent() then
                TouchActivity()
            end
            if CL.UI and CL.UI.RestoreAllWindows then
                CL.UI.RestoreAllWindows()
            end
            -- Same timing issue as UI.Show() above - the minimap button
            -- is created at file-load time (before real SavedVariables
            -- are restored), so its shown/hidden state has to be synced
            -- here rather than decided at creation.
            if CL.UIOptions then
                CL.UIOptions.RefreshMinimapVisibility()
                CL.UIOptions.RefreshMinimapPosition()
            end
        end
        return
    end

    if event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" or event == "UNIT_PET" then
        -- UNIT_PET covers summon/dismiss/death mid-session - roster
        -- refresh on party/raid change alone misses a pet that appears
        -- or disappears without the group composition itself changing.
        CL.GuidCache.RefreshRoster()
        if event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
            -- Only the two real group-composition events, not UNIT_PET -
            -- a pet appearing/disappearing doesn't change whether the
            -- player is grouped, which is all this checks.
            if CL.UI and CL.UI.ReconcileGroupVisibility then
                CL.UI.ReconcileGroupVisibility()
            end
            local grouped = IsGrouped()
            if grouped and not wasGrouped then
                local mode = CL.GetSetting("clearOnJoinPartyMode")
                if mode == "always" then
                    CL.Aggregator.ResetOverall()
                    if CL.UI and CL.UI.RefreshAllInstances then CL.UI.RefreshAllInstances() end
                    CL.Print("Overall cleared - joined a group.")
                elseif mode == "ask" then
                    StaticPopup_Show("COMBATLEDGER_CLEAR_ON_JOIN")
                end
            end
            wasGrouped = grouped
        end
        return
    end

    if event == "PLAYER_LOGOUT" then
        CL.FlushLog()
        -- Also fires on /reload (not just a real logout) - without this,
        -- the in-progress fight and the whole session's Overall totals
        -- would be silently lost on every reload, since they only exist
        -- as Lua locals otherwise. See Aggregator.lua's
        -- SerializeState/RestoreState.
        CombatLedgerDB.liveState = CL.Aggregator.SerializeState()

        -- Remembers the main window's exact shown/hidden state so
        -- closing it (via /cl hide, /cl toggle, or the minimap icon)
        -- actually sticks across a logout/reload - UI.RestoreAllWindows
        -- otherwise unconditionally shows it again next login regardless
        -- of having just been closed, since none of its other
        -- suppression rules (Auto-hide/Grouped-only) have anything to do
        -- with a direct manual close.
        local mainInst = CL.UIWindows and CL.UIWindows["main"]
        CL.SetSetting("mainWindowHidden", not (mainInst and mainInst.frame and mainInst.frame:IsShown()))
        return
    end

    if event == "PLAYER_REGEN_DISABLED" then
        LogRegenDiagnostic("DISABLED")
        TouchActivity()
        -- Used to eagerly StartEncounter() right here - removed.
        -- UnitAffectingCombat flipping true isn't proof a real fight is
        -- starting: Warrior's Bloodrage deals damage to itself as its
        -- whole mechanic, which flags the player "in combat" with zero
        -- enemy involved. Confirmed via user report - topping off rage
        -- between pulls (or just idly) was spinning up a brand new blank
        -- encounter, which immediately nil'd lastFinished (see
        -- StartEncounter's own comment) and blanked out whatever real
        -- fight's frozen summary "Current Fight" was showing, a few
        -- seconds before FinishEncounter froze that same empty encounter
        -- right on top of it.
        --
        -- Every real combat-exclusive Record* (RecordDamage/
        -- RecordAvoidance/RecordInterrupt/RecordDebuffGiven) already has
        -- its own lazy "if not current then StartEncounter()" fallback
        -- guarded by ShouldLazyStart - for an actual pull, the first
        -- real hit against an enemy fires this same tick (or the very
        -- next one), so encounter start is still effectively immediate.
        -- Training dummies already relied on this exact lazy path anyway
        -- (see ShouldLazyStart's own comment - dummies don't reliably
        -- flip UnitAffectingCombat at all, so this handler often never
        -- even fired for them in the first place).
        if CL.UI and CL.UI.ApplyAutoShow then
            CL.UI.ApplyAutoShow()
        end
        return
    end

    if event == "PLAYER_REGEN_ENABLED" then
        LogRegenDiagnostic("ENABLED")
        FinishEncounter()
        return
    end

    if event == "AUTO_ATTACK_SELF" then
        HandleAutoAttack(true, arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8)
        return
    end
    if event == "AUTO_ATTACK_OTHER" then
        HandleAutoAttack(false, arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8)
        return
    end

    if event == "SPELL_DAMAGE_EVENT_SELF" then
        HandleSpellDamage(true, arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8)
        return
    end
    if event == "SPELL_DAMAGE_EVENT_OTHER" then
        HandleSpellDamage(false, arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8)
        return
    end

    if event == "SPELL_GO_SELF" then
        HandleSpellGo(true, arg1, arg2, arg3, arg4, arg5, arg6, arg7)
        return
    end
    if event == "SPELL_GO_OTHER" then
        HandleSpellGo(false, arg1, arg2, arg3, arg4, arg5, arg6, arg7)
        return
    end

    -- SPELL_HEAL_ON_SELF deliberately NOT handled (not even registered
    -- below) - confirmed via debug log to always double-fire alongside
    -- whichever BY_* event already covers the same heal (BY_SELF for a
    -- self-cast heal, BY_OTHER for an incoming heal from someone else -
    -- both were logging the identical heal twice, once as tgt=player
    -- caster=X via BY_OTHER, once via ON_SELF). BY_SELF + BY_OTHER
    -- already cover every possible caster, so ON_SELF is a pure
    -- duplicate whenever you're the one being healed.
    if event == "SPELL_HEAL_BY_SELF" or event == "SPELL_HEAL_BY_OTHER" then
        HandleSpellHeal(arg1, arg2, arg3, arg4, arg5, arg6)
        return
    end

    if event == "SPELL_MISS_SELF" or event == "SPELL_MISS_OTHER" then
        TouchActivity()
        LogRawEvent(event)
        return
    end

    if event == "ENVIRONMENTAL_DMG_SELF" or event == "ENVIRONMENTAL_DMG_OTHER" then
        TouchActivity()
        LogRawEvent(event)
        return
    end

    if event == "DAMAGE_SHIELD_SELF" then
        HandleDamageShield(true, arg1, arg2, arg3, arg4)
        return
    end
    if event == "DAMAGE_SHIELD_OTHER" then
        HandleDamageShield(false, arg1, arg2, arg3, arg4)
        return
    end

    if event == "SPELL_ENERGIZE_BY_SELF" or event == "SPELL_ENERGIZE_BY_OTHER" or event == "SPELL_ENERGIZE_ON_SELF" then
        LogRawEvent(event)
        return
    end

    -- Shape: casterGuid, targetGuid, spellId - see HandleSpellDispel
    -- above.
    if event == "SPELL_DISPEL_BY_SELF" or event == "SPELL_DISPEL_BY_OTHER" then
        HandleSpellDispel(arg1, arg2, arg3)
        return
    end

    -- Debuffs given - see HandleAuraCast/HandleDebuffAdded above for the
    -- correlation mechanism.
    if event == "AURA_CAST_ON_SELF" or event == "AURA_CAST_ON_OTHER" then
        HandleAuraCast(arg1, arg2, arg3)
        return
    end

    if event == "DEBUFF_ADDED_SELF" or event == "DEBUFF_ADDED_OTHER" then
        HandleDebuffAdded(arg1, arg3)
        return
    end

    if event == "UNIT_DIED" then
        if arg1 then
            local attributed = CL.Aggregator.RecordDeath(arg1)
            -- Auto-open only for the player's own death (a raid wipe would
            -- otherwise fire this repeatedly, popping over itself) - other
            -- tracked deaths still get a recap recorded, just not shown.
            if attributed and CL.UIDeathRecap then
                local ok, exists, playerGuid = pcall(UnitExists, "player")
                if ok and exists and attributed == playerGuid then
                    CL.UIDeathRecap.Show(attributed)
                end
            end
        end
        return
    end
end)

-- Flushing the log buffer to disk on every single event would be a lot
-- of file I/O during a real fight (see Core.lua's LogLine comment) - this
-- throttles it to roughly once a second instead, using the same
-- OnUpdate the end-of-encounter checks below already run on.
local flushAccum = 0
local idleSuppressedLogged = false
f:SetScript("OnUpdate", function()
    flushAccum = flushAccum + arg1
    if flushAccum >= 1 then
        flushAccum = 0
        CL.FlushLog()
        -- Same ~1s cadence: sweep any AURA_CAST that never got matched
        -- to a DEBUFF_ADDED - includes every buff-side entry (BUFF_ADDED
        -- isn't registered, see HandleAuraCast's comment) plus genuinely
        -- unmatched debuffs (filtered target, edge case aura with no
        -- slot event, ...) - so pendingAuraCasts doesn't grow unbounded
        -- over a long session.
        local key, pending
        for key, pending in pairs(pendingAuraCasts) do
            if (GetTime() - pending.time) > PENDING_AURA_WINDOW then
                pendingAuraCasts[key] = nil
            end
        end
    end

    if CL.Aggregator.GetCurrent() and lastEventTime > 0 and (GetTime() - lastEventTime) > CL.IDLE_SECONDS then
        -- This fallback exists for targets that never toggle regen at
        -- all (training dummies) - solo, that's the only way an
        -- encounter against one would ever end. But in a group, a local
        -- lull in events the player happens to be involved in doesn't
        -- mean the raid stopped fighting (e.g. a healer standing off to
        -- the side of a melee pack can easily see 12+ quiet seconds of
        -- its own). Same guard as the regen path: don't let this fire
        -- while someone else in the group is still actually in combat,
        -- or this ends the encounter and Aggregator.lua's lazy
        -- "if not current then StartEncounter()" immediately spins up a
        -- new one on the very next raid-wide event, fragmenting one
        -- continuous pull into several.
        local grouped = ((GetNumRaidMembers and GetNumRaidMembers()) or 0) > 0
            or ((GetNumPartyMembers and GetNumPartyMembers()) or 0) > 0
        if not grouped or not AnyGroupMemberInCombat() then
            if CL.debug and grouped and idleSuppressedLogged then
                CL.LogLine("[REGEN] idle-timeout finishing - group also clear")
            end
            idleSuppressedLogged = false
            FinishEncounter()
        else
            if CL.debug and not idleSuppressedLogged then
                CL.LogLine("[REGEN] idle-timeout suppressed - group still in combat")
            end
            idleSuppressedLogged = true
        end
    else
        idleSuppressedLogged = false
    end
end)

f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("PLAYER_LOGOUT")
f:RegisterEvent("PARTY_MEMBERS_CHANGED")
f:RegisterEvent("RAID_ROSTER_UPDATE")
f:RegisterEvent("UNIT_PET")
f:RegisterEvent("PLAYER_REGEN_DISABLED")
f:RegisterEvent("PLAYER_REGEN_ENABLED")
f:RegisterEvent("AUTO_ATTACK_SELF")
f:RegisterEvent("AUTO_ATTACK_OTHER")
f:RegisterEvent("SPELL_DAMAGE_EVENT_SELF")
f:RegisterEvent("SPELL_DAMAGE_EVENT_OTHER")
f:RegisterEvent("SPELL_GO_SELF")
f:RegisterEvent("SPELL_GO_OTHER")
f:RegisterEvent("SPELL_HEAL_BY_SELF")
f:RegisterEvent("SPELL_HEAL_BY_OTHER")
-- SPELL_HEAL_ON_SELF not registered - see OnEvent's comment, it's a
-- confirmed duplicate of BY_SELF/BY_OTHER whenever you're healed.
f:RegisterEvent("SPELL_MISS_SELF")
f:RegisterEvent("SPELL_MISS_OTHER")
f:RegisterEvent("ENVIRONMENTAL_DMG_SELF")
f:RegisterEvent("ENVIRONMENTAL_DMG_OTHER")
f:RegisterEvent("DAMAGE_SHIELD_SELF")
f:RegisterEvent("DAMAGE_SHIELD_OTHER")
f:RegisterEvent("SPELL_ENERGIZE_BY_SELF")
f:RegisterEvent("SPELL_ENERGIZE_BY_OTHER")
f:RegisterEvent("SPELL_ENERGIZE_ON_SELF")
f:RegisterEvent("SPELL_DISPEL_BY_SELF")
f:RegisterEvent("SPELL_DISPEL_BY_OTHER")
f:RegisterEvent("AURA_CAST_ON_SELF")
f:RegisterEvent("AURA_CAST_ON_OTHER")
f:RegisterEvent("DEBUFF_ADDED_SELF")
f:RegisterEvent("DEBUFF_ADDED_OTHER")
f:RegisterEvent("UNIT_DIED")

-- /cl status walks current.units - table.getn doesn't work on a
-- guid-keyed table, so it needs CL.TableCount too; simplest to keep the
-- printed unit list here rather than exposing internals from Aggregator.
local function PrintStatus()
    local cur = CL.Aggregator.GetCurrent()
    if not cur then
        CL.Print("No live encounter.")
        return
    end
    CL.Print(string.format("Live encounter: %.1fs elapsed, %d unit(s) tracked.",
        GetTime() - cur.startTime, CL.TableCount(cur.units)))
    local guid, u
    for guid, u in pairs(cur.units) do
        CL.Print(string.format("  %s - dmgDone=%d dmgTaken=%d healDone=%d deaths=%d",
            tostring(u.name), u.damageDone.total, u.damageTaken.total, u.healingDone.total, u.deaths))
    end
end

SLASH_COMBATLEDGER1 = "/cl"
-- Manual reclassification: moves a plain-history encounter into the
-- Bosses bucket (see History.lua's SaveBossEncounter) by hand. Exists
-- for two real cases, not just testing: (1) a fight saved BEFORE the
-- Bosses feature existed, which can never retroactively gain isBossFight
-- on its own, and (2) IsBossTaggedEnemy's worldboss/elite-with-no-level
-- heuristic missing some private-server-specific mob that's a real boss
-- in-game but doesn't classify as one. Substring match against the saved
-- label (case-insensitive, since msg already arrives lowercased below),
-- not an exact match or index number - easier to type correctly than
-- counting rows in the history window. Can't retroactively invent
-- abilitySeries data that was never recorded live (see UI_EncounterReport's
-- own comment on this) - the Abilities graph just stays empty for a fight
-- tagged this way.
local function TagHistoryEncounterAsBoss(query)
    if not CL.History then return end
    local hist = CL.History.GetHistory()
    local i
    for i = 1, table.getn(hist) do
        local entry = hist[i]
        local label = entry.label or ""
        if string.find(string.lower(label), query, 1, true) then
            CL.History.DeleteEncounter(i)
            entry.isBossFight = true
            CL.History.SaveBossEncounter(entry)
            CL.Print("Tagged \"" .. label .. "\" as a boss kill - see /cl history's Bosses tab.")
            if CL.UIHistory and CL.UIHistory.Refresh then CL.UIHistory.Refresh() end
            return
        end
    end
    CL.Print("No saved encounter matching \"" .. query .. "\" found in History.")
end

SlashCmdList["COMBATLEDGER"] = function(msg)
    msg = string.lower(msg or "")
    if msg == "debug" then
        CL.debug = not CL.debug
        -- Persisted (not just a runtime flag) so it survives a relaunch -
        -- CL.debug used to always reset to false on load, meaning it was
        -- structurally impossible to ever capture PLAYER_ENTERING_WORLD's
        -- own debug output (it fires before you can ever type /cl debug
        -- on a fresh login). Turn it on once and it stays on for the
        -- next login too, until toggled off again.
        CombatLedgerDB.settings.debug = CL.debug
        CL.Print("Debug " .. (CL.debug and "ON" or "OFF"))
    elseif msg == "status" then
        PrintStatus()
    elseif msg == "flush" then
        if not WriteCustomFile then
            CL.Print("WriteCustomFile isn't available on this Nampower build - can't write the debug log to file.")
        else
            CL.FlushLog()
            CL.Print("Log flushed to " .. CL.LOG_FILENAME .. ".")
        end
    elseif msg == "show" then
        if CL.UI then CL.UI.Show() end
    elseif msg == "hide" then
        if CL.UI then CL.UI.Hide() end
    elseif msg == "toggle" or msg == "" then
        if CL.UI then CL.UI.Toggle() end
    elseif msg == "history" then
        if CL.UIHistory then CL.UIHistory.Toggle() end
    elseif msg == "report" then
        local enc = CL.Aggregator.GetCurrentDisplay()
        if enc and CL.UIEncounterReport then
            CL.UIEncounterReport.Show(enc)
        else
            CL.Print("No current or recent encounter to report on yet.")
        end
    elseif msg == "options" or msg == "opt" then
        if CL.UIOptions then CL.UIOptions.Toggle() end
    elseif string.find(msg, "^tagboss ") then
        local query = string.sub(msg, string.len("tagboss ") + 1)
        if query == "" then
            CL.Print("Usage: /cl tagboss <name or part of the saved encounter's label>")
        else
            TagHistoryEncounterAsBoss(query)
        end
    elseif msg == "testdeath" then
        -- Snapshots whatever's currently in your rolling hit-history
        -- buffer and shows the recap, without touching the real death
        -- counter - fight something for a few seconds then run this,
        -- rather than actually dying to test the window.
        local ok, exists, playerGuid = pcall(UnitExists, "player")
        if ok and exists and playerGuid then
            CL.Aggregator.SnapshotDeathRecap(playerGuid)
            if CL.UIDeathRecap then CL.UIDeathRecap.Show(playerGuid) end
        end
    else
        CL.Print("/cl toggle|show|hide - meter window. /cl options - lock/minimap/appearance settings. /cl history - saved encounters. /cl tagboss <name> - reclassify a saved encounter as a boss kill. /cl report - graph + leaderboard for the current/last fight. /cl testdeath - preview the death recap without dying. /cl debug - toggle event logging. /cl status - live encounter totals. /cl flush - force-write the debug log now.")
    end
end

EnableCVars()
CL.Print("Loaded. /cl toggle to show the meter, /cl options for settings, /cl help for commands.")
