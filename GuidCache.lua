--[[
    GuidCache - resolves a raw GUID (as combat events give us) to a
    name/class/level, independent of whether that unit currently occupies
    a live unit token. In vanilla, a GUID from a combat event is normally
    a dead end unless the unit is targeted right then, which is why most
    vanilla meters fall back to parsing chat text (the server already
    bakes the name into the string).

    GetUnitData(guid) returns none of name/class/type - only internal
    engine data (health, power, byte-packed race/class in bytes0/bytes2,
    stats, auras) - so it can't be used to resolve identity. This
    client's SuperWoW lets a raw GUID stand in for a normal unit token
    instead, so UnitName(guid)/UnitClass(guid)/UnitIsPlayer(guid) resolve
    it directly. GetUnitData is kept only for the numeric field it does
    have (level).
]]

local CL = CombatLedger

-- [guid] = { name, class, classToken, isPlayer, level, lastSeen }
local cache = {}
local STALE_TIMEOUT = 300 -- seconds a cache entry is kept before eviction

local dumpedOnce = false

local function DumpFields(guid, data)
    CL.LogLine("GetUnitData(" .. tostring(guid) .. ") raw fields:")
    local k, v
    for k, v in pairs(data) do
        CL.LogLine("  " .. tostring(k) .. " = " .. tostring(v))
    end
end

local function Resolve(guid)
    if not guid or guid == "" or guid == "0x0000000000000000" then return nil end

    local entry = cache[guid]
    if entry then
        entry.lastSeen = GetTime()
        return entry
    end

    -- pcall-guarded: on this client, UnitName(guid) doesn't just return
    -- nil for a guid string it can't resolve to a live unit - it can
    -- hard-error ("Unknown unit name: ...") instead, which would
    -- otherwise take down whatever combat event triggered this Resolve.
    local name
    if UnitName then
        local ok, result = pcall(UnitName, guid)
        if ok then name = result end
    end
    if not name or name == "" then return nil end -- unit not currently resolvable; retry next time

    local isPlayer = UnitIsPlayer and UnitIsPlayer(guid)

    local class, classToken
    if UnitClass then
        local ok, localized, token = pcall(UnitClass, guid)
        if ok then
            class, classToken = localized, token
        end
    end

    local level
    if GetUnitData then
        local ok, data = pcall(GetUnitData, guid)
        if ok and data then
            level = data.level
            if CL.debug and not dumpedOnce then
                dumpedOnce = true
                DumpFields(guid, data)
            end
        end
    end

    entry = {
        name = name,
        class = class,
        classToken = classToken,
        isPlayer = isPlayer,
        level = level,
        lastSeen = GetTime(),
    }
    cache[guid] = entry
    return entry
end

local function Purge()
    cache = {}
    dumpedOnce = false
end

local function CleanupStale()
    local now = GetTime()
    local toRemove = {}
    local guid, entry
    for guid, entry in pairs(cache) do
        if now - entry.lastSeen > STALE_TIMEOUT then
            table.insert(toRemove, guid)
        end
    end
    local i
    for i = 1, table.getn(toRemove) do
        cache[toRemove[i]] = nil
    end
end

--------------------------------------------------------------------------
-- Roster scope - which GUIDs are "ours" (player, party/raid, their pets).
-- Nampower's *_OTHER combat events aren't scoped to your group by
-- themselves - without this, a random unrelated player fighting a
-- different mob nearby would show up as if they were part of the fight.
-- Events.lua only records an event if at least one side (source or
-- target) is in this set.
--------------------------------------------------------------------------

local tracked = {}
local petOwner = {} -- [petGuid] = ownerGuid, so a pet's damage/healing can roll up under its owner's bar

-- pcall-wrapped: a malformed unit token string can throw, and a hard
-- error out of RefreshRoster would leave `tracked` half-built for the
-- rest of the fight rather than just skipping one bad token. ownerUnit,
-- when given, records this unit's GUID as owned by ownerUnit's GUID
-- (pets only).
local function AddUnit(unit, ownerUnit)
    local ok, exists, guid = pcall(UnitExists, unit)
    if ok and exists and guid then
        tracked[guid] = true
        if ownerUnit then
            local ownerOk, ownerExists, ownerGuid = pcall(UnitExists, ownerUnit)
            if ownerOk and ownerExists and ownerGuid then
                petOwner[guid] = ownerGuid
            end
        end
    end
end

local function RefreshRoster()
    tracked = {}
    petOwner = {}
    AddUnit("player")
    AddUnit("pet", "player")

    if GetNumRaidMembers and GetNumRaidMembers() > 0 then
        local i
        for i = 1, 40 do
            AddUnit("raid" .. i)
            -- Nampower's extended raid pet tokens use a "<base>pet"
            -- suffix ("raid5pet"), unlike party's native "partypetN"
            -- prefix convention - easy to mix up.
            AddUnit("raid" .. i .. "pet", "raid" .. i)
        end
    elseif GetNumPartyMembers and GetNumPartyMembers() > 0 then
        local i
        for i = 1, 4 do
            AddUnit("party" .. i)
            AddUnit("partypet" .. i, "party" .. i)
        end
    end
end

local function IsTracked(guid)
    if not guid then return false end
    return tracked[guid] == true
end

local function GetOwner(guid)
    if not guid then return nil end
    return petOwner[guid]
end

-- Reverse of GetOwner - which pet (if any) belongs to this owner guid.
-- Only Threat.lua needs this direction (to give a split-out pet threat
-- row its own real guid/name instead of a synthetic one) - the regular
-- damage/healing meters only ever need the forward petOwner -> owner
-- direction above, to roll a pet's numbers into its owner's bar.
-- petOwner is small (at most one entry per raid/party slot), so a linear
-- scan here is fine.
local function GetPetGuid(ownerGuid)
    if not ownerGuid then return nil end
    local pGuid, oGuid
    for pGuid, oGuid in pairs(petOwner) do
        if oGuid == ownerGuid then return pGuid end
    end
    return nil
end

CL.GuidCache = {
    Resolve = Resolve,
    Purge = Purge,
    CleanupStale = CleanupStale,
    RefreshRoster = RefreshRoster,
    IsTracked = IsTracked,
    GetOwner = GetOwner,
    GetPetGuid = GetPetGuid,
}
