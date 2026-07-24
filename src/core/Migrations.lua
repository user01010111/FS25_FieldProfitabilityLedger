FieldProfitabilityLedger = FieldProfitabilityLedger or {}
FieldProfitabilityLedger.Core = FieldProfitabilityLedger.Core or {}

local Migrations = {}

local REGISTRY_MARKER = {}
local MAX_SCHEMA_VERSION = 2147483647
local MAX_FINITE = 1.7976931348623157e308

local COPY_LIMITS = {
    maxDepth = 64,
    maxItems = 100000,
    maxNumber = 9007199254740991,
    maxStringBytes = 128
}

local HARD_COPY_LIMITS = {
    maxDepth = 256,
    maxItems = 1000000,
    maxStringBytes = 1024 * 1024
}

-- Public copy for integration diagnostics; the mechanics use the private
-- table above so callers cannot weaken the ceilings by mutation.
Migrations.COPY_LIMITS = {
    maxDepth = COPY_LIMITS.maxDepth,
    maxItems = COPY_LIMITS.maxItems,
    maxNumber = COPY_LIMITS.maxNumber,
    maxStringBytes = COPY_LIMITS.maxStringBytes
}

local function isFinite(value)
    return type(value) == "number"
        and value == value
        and value > -math.huge
        and value < math.huge
end

local function isInteger(value)
    return isFinite(value) and value == math.floor(value)
end

local function resolveCopyLimits()
    local constants = rawget(FieldProfitabilityLedger.Core, "Constants")
    if constants == nil then
        return {
            maxDepth = COPY_LIMITS.maxDepth,
            maxItems = COPY_LIMITS.maxItems,
            maxNumber = COPY_LIMITS.maxNumber,
            maxStringBytes = COPY_LIMITS.maxStringBytes
        }
    end
    if type(constants) ~= "table" or getmetatable(constants) ~= nil then
        return nil, "invalid_limits"
    end

    local policy = rawget(constants, "LIMITS")
    if type(policy) ~= "table" or getmetatable(policy) ~= nil then
        return nil, "invalid_limits"
    end

    local maxDepth = rawget(policy, "maxNeutralDepth")
    local maxItems = rawget(policy, "maxNeutralItems")
    local maxStringBytes = rawget(policy, "textBytes")
    local maxNumber = rawget(policy, "maxIdentifier")
    if not isInteger(maxDepth)
        or maxDepth < 0
        or maxDepth > HARD_COPY_LIMITS.maxDepth
        or not isInteger(maxItems)
        or maxItems < 1
        or maxItems > HARD_COPY_LIMITS.maxItems
        or not isInteger(maxStringBytes)
        or maxStringBytes < 0
        or maxStringBytes > HARD_COPY_LIMITS.maxStringBytes
        or not isFinite(maxNumber)
        or maxNumber < 1
        or maxNumber > MAX_FINITE then
        return nil, "invalid_limits"
    end

    return {
        maxDepth = maxDepth,
        maxItems = maxItems,
        maxNumber = maxNumber,
        maxStringBytes = maxStringBytes
    }
end

local function compareByteStrings(left, right)
    local sharedLength = math.min(#left, #right)
    local index
    for index = 1, sharedLength do
        local leftByte = string.byte(left, index)
        local rightByte = string.byte(right, index)
        if leftByte < rightByte then
            return -1
        elseif leftByte > rightByte then
            return 1
        end
    end
    if #left < #right then
        return -1
    elseif #left > #right then
        return 1
    end
    return 0
end

local function byteStringLess(left, right)
    return compareByteStrings(left, right) < 0
end

local function classifyTable(value, limits, remainingItems)
    if getmetatable(value) ~= nil then
        return nil, nil, "metatable"
    end

    local numericCount = 0
    local oversizedString = false
    local stringCount = 0
    local maximumIndex = 0
    local key
    for key in next, value do
        if numericCount + stringCount >= remainingItems then
            return nil, nil, "items_limit"
        end
        local keyType = type(key)
        if keyType == "number" then
            if not isInteger(key) or key < 1 then
                return nil, nil, "invalid_array_index"
            end
            numericCount = numericCount + 1
            if key > maximumIndex then
                maximumIndex = key
            end
        elseif keyType == "string" then
            stringCount = stringCount + 1
            if #key > limits.maxStringBytes then
                oversizedString = true
            end
        else
            return nil, nil, "invalid_table_key"
        end
    end

    if numericCount > 0 and stringCount > 0 then
        return nil, nil, "mixed_table"
    end
    if numericCount > 0 then
        if maximumIndex > limits.maxItems then
            return nil, nil, "items_limit"
        end
        if maximumIndex ~= numericCount then
            return nil, nil, "sparse_array"
        end
        return "array", numericCount
    end
    if stringCount > 0 then
        if oversizedString then
            return nil, nil, "string_limit"
        end
        return "map", stringCount
    end
    return "array", 0
end

local function sortedStringKeys(value, maximumItems, maximumStringBytes)
    local keys = {}
    local key
    for key in next, value do
        if #keys >= maximumItems then
            return nil, "items_limit"
        end
        if type(key) ~= "string" then
            return nil, "invalid_table_key"
        end
        if #key > maximumStringBytes then
            return nil, "string_limit"
        end
        keys[#keys + 1] = key
    end
    table.sort(keys, byteStringLess)
    return keys
end

local function neutralCopy(value, limits)
    local state = {
        active = {},
        items = 0,
        seen = {}
    }

    local copyValue
    copyValue = function(current, depth)
        if depth > limits.maxDepth then
            return nil, "depth_limit"
        end
        state.items = state.items + 1
        if state.items > limits.maxItems then
            return nil, "items_limit"
        end

        local valueType = type(current)
        if valueType == "nil" or valueType == "boolean" then
            return current
        elseif valueType == "number" then
            if not isFinite(current) then
                return nil, "non_finite"
            end
            if current < -limits.maxNumber or current > limits.maxNumber then
                return nil, "number_bounds"
            end
            if current == 0 then
                return 0
            end
            return current
        elseif valueType == "string" then
            if #current > limits.maxStringBytes then
                return nil, "string_limit"
            end
            return current
        elseif valueType ~= "table" then
            return nil, "unsupported_type"
        end

        if state.seen[current] then
            if state.active[current] then
                return nil, "cycle"
            end
            return nil, "shared_reference"
        end
        state.seen[current] = true
        state.active[current] = true

        local remainingItems = limits.maxItems - state.items
        local tableKind, count, tableReason = classifyTable(
            current,
            limits,
            remainingItems
        )
        if tableKind == nil then
            return nil, tableReason
        end

        local result = {}
        local index
        if tableKind == "array" then
            for index = 1, count do
                local copied, copyReason = copyValue(rawget(current, index), depth + 1)
                if copyReason ~= nil then
                    return nil, copyReason
                end
                result[index] = copied
            end
        else
            local keys, keyReason = sortedStringKeys(
                current,
                remainingItems,
                limits.maxStringBytes
            )
            if keys == nil then
                return nil, keyReason
            end
            for index = 1, #keys do
                local key = keys[index]
                local copied, copyReason = copyValue(rawget(current, key), depth + 1)
                if copyReason ~= nil then
                    return nil, copyReason
                end
                result[key] = copied
            end
        end

        state.active[current] = nil
        return result
    end

    return copyValue(value, 0)
end

local function validSchemaVersion(value, allowZero)
    if not isInteger(value) then
        return false
    end
    local minimum = allowZero and 0 or 1
    return value >= minimum and value <= MAX_SCHEMA_VERSION
end

local function validateRegistry(registry)
    if type(registry) ~= "table"
        or rawget(registry, REGISTRY_MARKER) ~= true
        or getmetatable(registry) ~= nil
        or not validSchemaVersion(rawget(registry, "currentVersion"), false)
        or type(rawget(registry, "steps")) ~= "table"
        or getmetatable(rawget(registry, "steps")) ~= nil then
        return nil, "invalid_registry"
    end

    local fromVersion, migrationFn
    for fromVersion, migrationFn in next, rawget(registry, "steps") do
        if not validSchemaVersion(fromVersion, true)
            or fromVersion >= registry.currentVersion
            or type(migrationFn) ~= "function" then
            return nil, "invalid_registry"
        end
    end
    return true
end

function Migrations.new(currentVersion)
    if not validSchemaVersion(currentVersion, false) then
        return nil, "invalid_version"
    end

    local registry = {
        currentVersion = currentVersion,
        steps = {}
    }
    registry[REGISTRY_MARKER] = true
    return registry
end

function Migrations.register(registry, fromVersion, migrationFn)
    local valid, registryReason = validateRegistry(registry)
    if not valid then
        return false, registryReason
    end
    if not validSchemaVersion(fromVersion, true)
        or fromVersion >= registry.currentVersion then
        return false, "invalid_step_version"
    end
    if type(migrationFn) ~= "function" then
        return false, "invalid_migration"
    end
    if rawget(registry.steps, fromVersion) ~= nil then
        return false, "duplicate_step"
    end

    registry.steps[fromVersion] = migrationFn
    return true
end

function Migrations.migrate(registry, document)
    local valid, registryReason = validateRegistry(registry)
    if not valid then
        return nil, registryReason
    end
    local copyLimits, limitsReason = resolveCopyLimits()
    if copyLimits == nil then
        return nil, limitsReason
    end
    if type(document) ~= "table" then
        return nil, "invalid_document"
    end

    local working, copyReason = neutralCopy(document, copyLimits)
    if working == nil then
        return nil, copyReason
    end

    local documentVersion = rawget(working, "schemaVersion")
    if documentVersion == nil then
        return nil, "missing_version"
    end
    if not validSchemaVersion(documentVersion, true) then
        return nil, "invalid_version"
    end
    if documentVersion > registry.currentVersion then
        return nil, "future_version"
    end
    if documentVersion == registry.currentVersion then
        return working
    end

    -- Preflight the whole chain before running any step.  A later gap cannot
    -- cause an earlier migration function to run and then be discarded.
    local version
    for version = documentVersion, registry.currentVersion - 1 do
        if type(rawget(registry.steps, version)) ~= "function" then
            return nil, "missing_step"
        end
    end

    for version = documentVersion, registry.currentVersion - 1 do
        local stepInput, stepCopyReason = neutralCopy(working, copyLimits)
        if stepInput == nil then
            return nil, stepCopyReason
        end

        local ok, migrated = pcall(registry.steps[version], stepInput)
        if not ok then
            return nil, "migration_error"
        end
        if migrated == nil then
            return nil, "migration_failed"
        end
        if type(migrated) ~= "table" then
            return nil, "invalid_document"
        end

        local migratedCopy, migratedCopyReason = neutralCopy(migrated, copyLimits)
        if migratedCopy == nil then
            return nil, migratedCopyReason
        end
        local migratedVersion = rawget(migratedCopy, "schemaVersion")
        if not validSchemaVersion(migratedVersion, true)
            or migratedVersion ~= version + 1 then
            return nil, "invalid_version_step"
        end
        working = migratedCopy
    end

    return working
end

FieldProfitabilityLedger.Core.Migrations = Migrations

return Migrations
