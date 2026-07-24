-- Validated client-local presentation preferences. These never affect Ledger totals.

FieldProfitabilityLedger = FieldProfitabilityLedger or {}
FieldProfitabilityLedger.Services = FieldProfitabilityLedger.Services or {}

local ClientSettings = {}
ClientSettings.__index = ClientSettings

local DEFAULTS = {
    schemaVersion = 2,
    newestFirst = true,
    showExcluded = true,
    cycleSortBy = "period",
    cycleSortDescending = true,
    includeDirect = true,
    includeInputs = true,
    includeFuel = true,
    includeDef = true,
    includeAllocated = true
}

local KEYS = {
    schemaVersion=true, newestFirst=true, showExcluded=true,
    cycleSortBy=true, cycleSortDescending=true, includeDirect=true,
    includeInputs=true, includeFuel=true, includeDef=true,
    includeAllocated=true
}

local BOOLEAN_KEYS = {
    "newestFirst", "showExcluded", "cycleSortDescending", "includeDirect",
    "includeInputs", "includeFuel", "includeDef", "includeAllocated"
}

local CYCLE_SORT_KEYS = {
    field=true, crop=true, state=true, period=true, area=true,
    yieldPerHa=true, valuePerHa=true, costPerHa=true,
    marginPerHa=true, quality=true
}

local V1_KEYS = {
    schemaVersion=true, pageSize=true, newestFirst=true, showExcluded=true,
    indicatorEnabled=true, stateFilter=true, includeDirect=true,
    includeInputs=true, includeFuel=true, includeDef=true,
    includeAllocated=true
}

local V1_BOOLEAN_KEYS = {
    "newestFirst", "showExcluded", "indicatorEnabled", "includeDirect",
    "includeInputs", "includeFuel", "includeDef", "includeAllocated"
}

local PAGE_SIZES = {[10]=true, [20]=true, [50]=true, [100]=true}
local STATE_FILTERS = {all=true, open=true, closed=true, archived=true}

local function serialization()
    local namespace = rawget(_G, "FieldProfitabilityLedger")
    local core = type(namespace) == "table" and rawget(namespace, "Core") or nil
    local value = type(core) == "table" and rawget(core, "Serialization") or nil
    if type(value) ~= "table" or type(value.encode) ~= "function"
        or type(value.decode) ~= "function" then
        return nil, "settingsSerializationUnavailable"
    end
    return value
end

local function copy(value)
    local result = {}
    for key, item in pairs(value) do result[key] = item end
    return result
end

local function validateKeys(value, keys)
    for key in next, value do
        if type(key) ~= "string" or keys[key] ~= true then
            return nil
        end
    end
    return true
end

local function migrateV1(value)
    if validateKeys(value, V1_KEYS) == nil
        or PAGE_SIZES[rawget(value, "pageSize")] ~= true
        or STATE_FILTERS[rawget(value, "stateFilter")] ~= true then
        return nil
    end
    for _, key in ipairs(V1_BOOLEAN_KEYS) do
        if type(rawget(value, key)) ~= "boolean" then return nil end
    end
    local result = copy(DEFAULTS)
    result.newestFirst = value.newestFirst
    result.showExcluded = value.showExcluded
    result.cycleSortDescending = value.newestFirst
    result.includeDirect = value.includeDirect
    result.includeInputs = value.includeInputs
    result.includeFuel = value.includeFuel
    result.includeDef = value.includeDef
    result.includeAllocated = value.includeAllocated
    return result
end

local function normalize(value)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        return nil, "invalidClientSettings"
    end
    if rawget(value, "schemaVersion") == 1 then
        local migrated = migrateV1(value)
        if migrated == nil then return nil, "invalidClientSettings" end
        return migrated, nil, true
    end
    if rawget(value, "schemaVersion") ~= 2
        or validateKeys(value, KEYS) == nil
        or CYCLE_SORT_KEYS[rawget(value, "cycleSortBy")] ~= true then
        return nil, "invalidClientSettings"
    end
    for _, key in ipairs(BOOLEAN_KEYS) do
        if type(rawget(value, key)) ~= "boolean" then
            return nil, "invalidClientSettings"
        end
    end
    return copy(value)
end

function ClientSettings.new(filePort)
    if type(filePort) ~= "table" or type(filePort.read) ~= "function"
        or type(filePort.write) ~= "function" then
        return nil, "invalidSettingsFilePort"
    end
    local codec, reason = serialization()
    if codec == nil then return nil, reason end
    return setmetatable({filePort=filePort, values=copy(DEFAULTS)}, ClientSettings)
end

function ClientSettings:load()
    local codec, reason = serialization()
    if codec == nil then return nil, reason end
    local encoded, readReason = self.filePort:read()
    if encoded == nil then
        self.values = copy(DEFAULTS)
        if readReason == "notFound" then
            return self:get(), {state="new"}
        end
        return self:get(), {state="reset", reason=readReason}
    end
    local decoded, decodeReason = codec.decode(encoded, {
        maxDepth=4, maxEncodedBytes=4096, maxItems=32,
        maxStringBytes=64, maxNumber=100
    })
    local accepted, validationReason, migrated = normalize(decoded)
    if accepted == nil then
        self.values = copy(DEFAULTS)
        return self:get(), {
            state="reset", reason=decodeReason or validationReason
        }
    end
    self.values = accepted
    return self:get(), {state=migrated and "migrated" or "loaded",
        fromSchema=migrated and 1 or nil}
end

function ClientSettings:get()
    return copy(self.values)
end

function ClientSettings:set(values)
    local accepted, reason = normalize(values)
    if accepted == nil then return nil, reason end
    local codec
    codec, reason = serialization()
    if codec == nil then return nil, reason end
    local encoded
    encoded, reason = codec.encode(accepted, {
        maxDepth=4, maxEncodedBytes=4096, maxItems=32,
        maxStringBytes=64, maxNumber=100
    })
    if encoded == nil then return nil, reason end
    local status
    status, reason = self.filePort:write(encoded)
    if status == nil then return nil, reason end
    self.values = accepted
    return self:get(), status
end

function ClientSettings.defaults()
    return copy(DEFAULTS)
end

FieldProfitabilityLedger.Services.ClientSettings = ClientSettings
return ClientSettings
