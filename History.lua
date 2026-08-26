--[[
    History - save/trim/delete for CombatLedgerDB.encountersByChar[key].
    Most-recent-first, capped at CL.MAX_ENCOUNTERS (trim-oldest) - PER
    CHARACTER, since CombatLedgerDB itself is account-wide (plain
    SavedVariables, not SavedVariablesPerCharacter - see the .toc) and a
    flat shared list meant every alt on the account saw every other alt's
    saved encounters mixed into the same history.

    Reads/writes the CombatLedgerDB global directly rather than through
    CL.db - SavedVariables are restored from disk after Core.lua's own
    init line runs, replacing the table wholesale (see Core.lua's
    EnsureSettingsTable for the same issue with .settings), so a cached
    table reference risks writing into an orphaned copy that never
    actually gets saved.

    encounter.series (Aggregator's bucketed damage/healing/taken-per-2s
    timeline) is real content, not scratch data like mobTally/mobHealth -
    it's kept through the save so UI_EncounterReport can graph a saved
    encounter, not just the live one.
]]

local CL = CombatLedger

local function CharKey()
    local name = UnitName("player") or "Unknown"
    local realm = (GetRealmName and GetRealmName()) or ""
    return name .. "-" .. realm
end

-- Returns the current character's own encounter list, creating it if
-- needed. Also does a one-time migration of the OLD account-wide flat
-- list (CombatLedgerDB.encounters, from before per-character history)
-- into whichever character happens to log in first after the update -
-- nobody silently loses their existing saved encounters, but it's
-- cleared immediately after so a second alt logging in doesn't also
-- re-import the same old shared list into its own bucket.
local function EnsureEncountersTable()
    if not CombatLedgerDB.encountersByChar then
        CombatLedgerDB.encountersByChar = {}
    end
    local key = CharKey()
    if not CombatLedgerDB.encountersByChar[key] then
        CombatLedgerDB.encountersByChar[key] = {}
    end
    if CombatLedgerDB.encounters and table.getn(CombatLedgerDB.encounters) > 0 then
        local i
        for i = 1, table.getn(CombatLedgerDB.encounters) do
            table.insert(CombatLedgerDB.encountersByChar[key], CombatLedgerDB.encounters[i])
        end
        CombatLedgerDB.encounters = nil
    end
    return key
end

-- Named after the toughest mob in the pull (highest UnitHealthMax
-- sampled while fighting it - see Aggregator's mobHealth) rather than
-- the zone name, since every boss pull inside an instance would
-- otherwise share the same zone name with nothing to tell separate
-- pulls apart in the segment dropdown/history list. Falls back to
-- whichever mob took the most tracked-side damage if health sampling
-- came up empty, then to the zone name.
local function ComputeLabel(encounter)
    local bestGuid, bestHealth = nil, 0
    local hpGuid, hp
    for hpGuid, hp in pairs(encounter.mobHealth or {}) do
        if hp > bestHealth then
            bestGuid, bestHealth = hpGuid, hp
        end
    end

    if not bestGuid then
        local bestAmount = 0
        local dmgGuid, amount
        for dmgGuid, amount in pairs(encounter.mobTally or {}) do
            if amount > bestAmount then
                bestGuid, bestAmount = dmgGuid, amount
            end
        end
    end

    if bestGuid then
        local info = CL.GuidCache and CL.GuidCache.Resolve(bestGuid)
        if info and info.name then return info.name end
    end

    if IsInInstance and IsInInstance() then
        return (GetRealZoneText and GetRealZoneText()) or encounter.zone or "Instance"
    end
    return encounter.zone or "Unknown"
end

local function SaveEncounter(encounter)
    if not encounter then return end
    local key = EnsureEncountersTable()
    local list = CombatLedgerDB.encountersByChar[key]

    if not encounter.label then
        encounter.label = ComputeLabel(encounter)
    end
    encounter.mobTally = nil -- label-only scratch data, not worth persisting
    encounter.mobHealth = nil -- label-only scratch data, not worth persisting

    table.insert(list, 1, encounter)
    while table.getn(list) > CL.MAX_ENCOUNTERS do
        table.remove(list, table.getn(list))
    end
end

local function GetHistory()
    local key = EnsureEncountersTable()
    return CombatLedgerDB.encountersByChar[key]
end

local function DeleteEncounter(index)
    local key = EnsureEncountersTable()
    table.remove(CombatLedgerDB.encountersByChar[key], index)
end

local function ClearHistory()
    local key = EnsureEncountersTable()
    CombatLedgerDB.encountersByChar[key] = {}
end

-- Boss kills get their OWN per-character bucket, keyed by boss name
-- (encounter.label) - the regular list above is a single flat, capped
-- (CL.MAX_ENCOUNTERS) most-recent-first list, so a busy trash-clearing
-- session can push a boss kill out before anyone gets a chance to look
-- at it. Keeping bosses separate, capped per-name instead of overall,
-- means killing Boss A ten times can never evict Boss B's saved kills.
local BOSS_KILLS_PER_BOSS = 10

local function EnsureBossTable()
    if not CombatLedgerDB.bossEncountersByChar then
        CombatLedgerDB.bossEncountersByChar = {}
    end
    local key = CharKey()
    if not CombatLedgerDB.bossEncountersByChar[key] then
        CombatLedgerDB.bossEncountersByChar[key] = {}
    end
    return key
end

local function SaveBossEncounter(encounter)
    if not encounter then return end
    local key = EnsureBossTable()
    local bosses = CombatLedgerDB.bossEncountersByChar[key]

    if not encounter.label then
        encounter.label = ComputeLabel(encounter)
    end
    encounter.mobTally = nil
    encounter.mobHealth = nil

    local name = encounter.label
    if not bosses[name] then bosses[name] = {} end
    local list = bosses[name]
    table.insert(list, 1, encounter)
    while table.getn(list) > BOSS_KILLS_PER_BOSS do
        table.remove(list, table.getn(list))
    end
end

-- [bossName] = { encounter, encounter, ... } - most-recent-first, same
-- shape as GetHistory's list but one level deeper (grouped by name).
local function GetBossHistory()
    local key = EnsureBossTable()
    return CombatLedgerDB.bossEncountersByChar[key]
end

local function DeleteBossEncounter(bossName, index)
    local key = EnsureBossTable()
    local list = CombatLedgerDB.bossEncountersByChar[key][bossName]
    if not list then return end
    table.remove(list, index)
    if table.getn(list) == 0 then
        CombatLedgerDB.bossEncountersByChar[key][bossName] = nil
    end
end

-- No bossName clears everything; a specific name clears just that boss.
local function ClearBossHistory(bossName)
    local key = EnsureBossTable()
    if bossName then
        CombatLedgerDB.bossEncountersByChar[key][bossName] = nil
    else
        CombatLedgerDB.bossEncountersByChar[key] = {}
    end
end

CL.History = {
    SaveEncounter = SaveEncounter,
    GetHistory = GetHistory,
    DeleteEncounter = DeleteEncounter,
    ClearHistory = ClearHistory,
    SaveBossEncounter = SaveBossEncounter,
    GetBossHistory = GetBossHistory,
    DeleteBossEncounter = DeleteBossEncounter,
    ClearBossHistory = ClearBossHistory,
}
