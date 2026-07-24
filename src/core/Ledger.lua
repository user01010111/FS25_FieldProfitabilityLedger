FieldProfitabilityLedger = FieldProfitabilityLedger or {}
FieldProfitabilityLedger.Core = FieldProfitabilityLedger.Core or {}

local Core = FieldProfitabilityLedger.Core
local Constants = Core.Constants

local Ledger = {}
Ledger.__index = Ledger
local directTransactionKey

local function dependencies()
    local validation = Core.Validation
    local identifiers = Core.Identifiers
    if validation == nil or identifiers == nil then
        return nil, nil, "coreDependencyUnavailable"
    end
    return validation, identifiers, nil
end

local function exactSumDependency()
    local exactSum = Core.ExactSum
    if type(exactSum) ~= "table"
        or type(exactSum.new) ~= "function"
        or type(exactSum.add) ~= "function"
        or type(exactSum.merge) ~= "function"
        or type(exactSum.finish) ~= "function"
        or type(exactSum.toNeutral) ~= "function"
        or type(exactSum.fromNeutral) ~= "function" then
        return nil, "exactSumUnavailable"
    end
    return exactSum
end

local function shallowCopy(source)
    local result = {}
    for key, value in pairs(source) do
        result[key] = value
    end
    return result
end

local function neutralCopy(value, maximumItems)
    local validation, _, dependencyError = dependencies()
    if dependencyError ~= nil then
        return nil, dependencyError
    end
    return validation.copy(value, {
        maxDepth = Constants.LIMITS.maxNeutralDepth,
        maxItems = maximumItems or Constants.LIMITS.maxNeutralItems,
        maxStringBytes = Constants.LIMITS.textBytes,
        maxNumber = math.max(
            Constants.LIMITS.maxMoney,
            Constants.LIMITS.maxDurationMs,
            Constants.LIMITS.maxIdentifier
        )
    })
end

local function validateToken(value, maximumBytes)
    local validation, _, dependencyError = dependencies()
    if dependencyError ~= nil then
        return nil, dependencyError
    end
    return validation.asciiToken(value, maximumBytes or Constants.LIMITS.tokenBytes)
end

local function validateNumber(value, minimum, maximum)
    local validation, _, dependencyError = dependencies()
    if dependencyError ~= nil then
        return nil, dependencyError
    end
    return validation.number(value, minimum, maximum)
end

local function validateInteger(value, minimum, maximum)
    local validation, _, dependencyError = dependencies()
    if dependencyError ~= nil then
        return nil, dependencyError
    end
    return validation.integer(value, minimum, maximum)
end

local function compareBytes(left, right)
    local sharedLength = math.min(string.len(left), string.len(right))
    for index = 1, sharedLength do
        local leftByte = string.byte(left, index)
        local rightByte = string.byte(right, index)
        if leftByte < rightByte then
            return -1
        elseif leftByte > rightByte then
            return 1
        end
    end
    if string.len(left) < string.len(right) then
        return -1
    elseif string.len(left) > string.len(right) then
        return 1
    end
    return 0
end

local function byteLess(left, right)
    return compareBytes(left, right) < 0
end

local function normalizeReasons(reasons)
    if reasons == nil then
        return {}
    end
    local validation, _, dependencyError = dependencies()
    if dependencyError ~= nil then
        return nil, dependencyError
    end
    local array, arrayError = validation.array(reasons, Constants.LIMITS.maxReasons)
    if array == nil then
        return nil, arrayError
    end
    local seen = {}
    local result = {}
    for _, reason in ipairs(array) do
        local token, tokenError = validation.asciiToken(reason, Constants.LIMITS.tokenBytes)
        if token == nil then
            return nil, tokenError
        end
        if not seen[token] then
            seen[token] = true
            result[#result + 1] = token
        end
    end
    table.sort(result, byteLess)
    return result
end

local function mergeReasons(left, right)
    local result = {}
    local seen = {}
    for _, source in ipairs({left or {}, right or {}}) do
        for _, reason in ipairs(source) do
            if not seen[reason] then
                if #result >= Constants.LIMITS.maxReasons then
                    return nil, "tooManyReasons"
                end
                seen[reason] = true
                result[#result + 1] = reason
            end
        end
    end
    table.sort(result, byteLess)
    return result
end

local QUALITY_RANK = {
    [Constants.QUALITY_CLASS.Complete] = 1,
    [Constants.QUALITY_CLASS.Partial] = 2,
    [Constants.QUALITY_CLASS.Unsupported] = 3
}

local function lowerQuality(left, right)
    if QUALITY_RANK[left] >= QUALITY_RANK[right] then
        return left
    end
    return right
end

local function validateMissionTime(value)
    return validateNumber(value, 0, Constants.LIMITS.maxMissionTime)
end

local function validateOptionalToken(value, maximumBytes)
    if value == nil then
        return nil, nil
    end
    return validateToken(value, maximumBytes)
end

local function validateNonEmptyText(value, maximumBytes, emptyReason)
    local validation, _, dependencyError = dependencies()
    if dependencyError ~= nil then
        return nil, dependencyError
    end
    local accepted, textError = validation.text(value, maximumBytes)
    if accepted == nil then
        return nil, textError
    end
    if accepted == "" then
        return nil, emptyReason
    end
    return accepted
end

local function validateLandKey(value)
    local _, identifiers, dependencyError = dependencies()
    if dependencyError ~= nil then
        return nil, dependencyError
    end
    local parts, parseError = identifiers.parseLandKey(value)
    if parts == nil then
        return nil, parseError
    end
    return parts
end

local function amountLimitForUnit(unit)
    return Constants.UNIT_LIMIT[unit]
end

local function validateStoredAmount(amount, unit)
    local maximum = amountLimitForUnit(unit)
    if maximum == nil then
        return nil, "invalidUnit"
    end
    return validateNumber(amount, 0, maximum)
end

local function validateDirection(accountingClass, qualityClass, value)
    if qualityClass == Constants.QUALITY_CLASS.Unsupported then
        if value ~= nil then
            return nil, "unsupportedDirectionMustBeAbsent"
        end
        return nil, nil
    end
    if accountingClass == Constants.ACCOUNTING_CLASS.Observed then
        if value ~= nil then
            return nil, "observedDirectionMustBeAbsent"
        end
        return nil, nil
    end
    local direction, directionError = validateToken(value)
    if direction == nil or not Constants.DIRECTION_SET[direction] then
        return nil, directionError or "invalidDirection"
    end
    return direction
end

local function lengthPrefixed(parts)
    local result = {}
    for index, part in ipairs(parts) do
        part = part or ""
        result[index] = string.format("%d:%s", string.len(part), part)
    end
    return table.concat(result, "|")
end

local function categoryAggregateKey(source)
    return lengthPrefixed({
        source.accountingClass,
        source.category,
        source.unit,
        source.direction
    })
end

local RETENTION_SUMMARY_KEYS = {
    compactedAtYear = true,
    directReplacementOverlap = true,
    entries = true,
    prunedRecordCount = true,
    prunedSessionCount = true
}

local RETENTION_ENTRY_KEYS = {
    accountingClass = true,
    category = true,
    direction = true,
    exactSum = true,
    qualityClass = true,
    reasons = true,
    recordType = true,
    sourceRecordCount = true,
    unit = true
}

local QUERY_OPTION_KEYS = {
    _retentionPlan = true,
    includeExcluded = true,
    includeLive = true,
    recordLimit = true,
    recordOffset = true
}

local LIST_CYCLE_OPTION_KEYS = {
    fieldGrouped = true,
    farmId = true,
    landKey = true,
    limit = true,
    newestFirst = true,
    offset = true,
    state = true,
    states = true
}

local function validateKnownFields(value, allowed, reasonCode)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        return nil, reasonCode
    end
    local maximumKeys = 0
    for _ in pairs(allowed) do
        maximumKeys = maximumKeys + 1
    end
    local visitedKeys = 0
    for key in next, value do
        visitedKeys = visitedKeys + 1
        if visitedKeys > maximumKeys then
            return nil, reasonCode
        end
        if type(key) ~= "string" or allowed[key] ~= true then
            return nil, reasonCode
        end
    end
    return value
end

local function retentionEntryKey(entry)
    return lengthPrefixed({
        entry.recordType,
        entry.accountingClass,
        entry.category,
        entry.qualityClass,
        entry.unit,
        entry.direction,
        lengthPrefixed(entry.reasons)
    })
end

local function reasonsContain(reasons, expected)
    for _, reason in ipairs(reasons or {}) do
        if reason == expected then
            return true
        end
    end
    return false
end

local function normalizeRetentionSummary(value)
    local summary, summaryError = validateKnownFields(
        value,
        RETENTION_SUMMARY_KEYS,
        "invalidRetentionSummary"
    )
    if summary == nil then
        return nil, summaryError
    end
    local compactedAtYear, yearError = validateInteger(
        summary.compactedAtYear,
        0,
        Constants.LIMITS.maxYear
    )
    if compactedAtYear == nil then
        return nil, yearError
    end
    if type(summary.directReplacementOverlap) ~= "boolean" then
        return nil, "invalidRetentionOverlap"
    end
    local prunedRecordCount, countError = validateInteger(
        summary.prunedRecordCount,
        0,
        Constants.LIMITS.maxRecords
    )
    if prunedRecordCount == nil then
        return nil, countError
    end
    local prunedSessionCount = nil
    prunedSessionCount, countError = validateInteger(
        summary.prunedSessionCount,
        0,
        Constants.LIMITS.maxRecords
    )
    if prunedSessionCount == nil then
        return nil, countError
    end
    local entries, entriesError = Core.Validation.array(
        summary.entries,
        Constants.LIMITS.maxComponents
    )
    if entries == nil then
        return nil, entriesError
    end
    local normalizedEntries = {}
    local representedRecords = 0
    local previousKey = nil
    local retainedCategoryStates = {}
    for index, source in ipairs(entries) do
        local entry, entryError = validateKnownFields(
            source,
            RETENTION_ENTRY_KEYS,
            "invalidRetentionEntry"
        )
        if entry == nil then
            return nil, entryError
        end
        local recordType, recordTypeError = validateToken(entry.recordType)
        if recordType == nil or recordType == Constants.RECORD_TYPE.Summary
            or not Constants.RECORD_TYPE_SET[recordType] then
            return nil, recordTypeError or "invalidRetentionRecordType"
        end
        local accountingClass = entry.accountingClass
        if not Constants.ACCOUNTING_CLASS_SET[accountingClass] then
            return nil, "invalidAccountingClass"
        end
        local qualityClass = entry.qualityClass
        if not Constants.QUALITY_CLASS_SET[qualityClass] then
            return nil, "invalidQualityClass"
        end
        local category, categoryError = validateToken(entry.category)
        if category == nil then
            return nil, categoryError
        end
        local reasons, reasonsError = normalizeReasons(entry.reasons)
        if reasons == nil then
            return nil, reasonsError
        end
        if qualityClass ~= Constants.QUALITY_CLASS.Complete and #reasons == 0 then
            return nil, "qualityReasonRequired"
        end
        if recordType == Constants.RECORD_TYPE.Valuation
            or accountingClass == Constants.ACCOUNTING_CLASS.Direct
            or category == "mixedBoundaryTick"
            or reasonsContain(reasons, "mixedBoundaryTick")
            or reasonsContain(reasons, "boundaryUnresolved") then
            return nil, "protectedRetentionEntry"
        end
        local sourceRecordCount = nil
        sourceRecordCount, countError = validateInteger(
            entry.sourceRecordCount,
            1,
            Constants.LIMITS.maxRecords
        )
        if sourceRecordCount == nil then
            return nil, countError
        end
        if representedRecords + sourceRecordCount > Constants.LIMITS.maxRecords then
            return nil, "retentionCountOutOfRange"
        end
        representedRecords = representedRecords + sourceRecordCount
        local exactState = nil
        local unit = nil
        local direction = nil
        if qualityClass == Constants.QUALITY_CLASS.Unsupported then
            if entry.exactSum ~= nil or entry.unit ~= nil or entry.direction ~= nil then
                return nil, "unsupportedRetentionAmount"
            end
        else
            unit, entryError = validateToken(entry.unit)
            if unit == nil or not Constants.UNIT_SET[unit] then
                return nil, entryError or "invalidUnit"
            end
            if accountingClass == Constants.ACCOUNTING_CLASS.Observed
                and unit == Constants.UNIT.Money then
                return nil, "observedMoneyForbidden"
            end
            if accountingClass ~= Constants.ACCOUNTING_CLASS.Observed
                and unit ~= Constants.UNIT.Money then
                return nil, "monetaryClassRequiresMoneyUnit"
            end
            direction, entryError = validateDirection(
                accountingClass,
                qualityClass,
                entry.direction
            )
            if entryError ~= nil then
                return nil, entryError
            end
            local exactSum, exactError = exactSumDependency()
            if exactSum == nil then
                return nil, exactError
            end
            local maximum = amountLimitForUnit(unit)
            local accumulator = nil
            accumulator, exactError = exactSum.fromNeutral(
                entry.exactSum,
                maximum,
                Constants.LIMITS.maxRecords
            )
            if accumulator == nil then
                return nil, exactError
            end
            exactState, exactError = exactSum.toNeutral(accumulator)
            if exactState == nil then
                return nil, exactError
            end
            if exactState.sign < 0 or exactState.terms ~= sourceRecordCount then
                return nil, "invalidRetentionExactSum"
            end
            local _, finishError = exactSum.finish(accumulator, maximum)
            if finishError ~= nil then
                return nil, finishError
            end
            local aggregateKey = categoryAggregateKey({
                accountingClass = accountingClass,
                category = category,
                unit = unit,
                direction = direction
            })
            local aggregate = retainedCategoryStates[aggregateKey]
            if aggregate == nil then
                local aggregateAccumulator = nil
                aggregateAccumulator, exactError = exactSum.new(
                    maximum,
                    Constants.LIMITS.maxRecords
                )
                if aggregateAccumulator == nil then
                    return nil, exactError
                end
                aggregate = {
                    accumulator = aggregateAccumulator,
                    maximum = maximum,
                    recordCount = 0
                }
                retainedCategoryStates[aggregateKey] = aggregate
            end
            if aggregate.recordCount + sourceRecordCount
                > Constants.LIMITS.maxRecords then
                return nil, "aggregateCountOutOfRange"
            end
            local merged, mergeError = exactSum.merge(
                aggregate.accumulator,
                exactState
            )
            if not merged then
                return nil, mergeError
            end
            aggregate.recordCount = aggregate.recordCount + sourceRecordCount
        end
        local normalized = {
            recordType = recordType,
            accountingClass = accountingClass,
            qualityClass = qualityClass,
            category = category,
            exactSum = exactState,
            unit = unit,
            direction = direction,
            sourceRecordCount = sourceRecordCount,
            reasons = reasons
        }
        local key = retentionEntryKey(normalized)
        if previousKey ~= nil and compareBytes(previousKey, key) >= 0 then
            return nil, "nonCanonicalRetentionEntries"
        end
        previousKey = key
        normalizedEntries[index] = normalized
    end
    local exactSum, exactError = exactSumDependency()
    if exactSum == nil then
        return nil, exactError
    end
    for _, aggregate in pairs(retainedCategoryStates) do
        local amount, finishError = exactSum.finish(
            aggregate.accumulator,
            aggregate.maximum
        )
        if amount == nil or amount < 0 then
            if finishError == nil or finishError == "aggregateOutOfRange" then
                return nil, "categoryTotalOutOfRange"
            end
            return nil, finishError
        end
    end
    if representedRecords ~= prunedRecordCount then
        return nil, "retentionCountMismatch"
    end
    return {
        compactedAtYear = compactedAtYear,
        directReplacementOverlap = summary.directReplacementOverlap,
        entries = normalizedEntries,
        prunedRecordCount = prunedRecordCount,
        prunedSessionCount = prunedSessionCount
    }
end

local function containsReservedField(value, visited)
    if type(value) ~= "table" then
        return false
    end
    visited = visited or {}
    if visited[value] then
        return false
    end
    visited[value] = true
    for key, child in pairs(value) do
        if key == "actualProfit" or key == "realizedProfit" then
            return true
        end
        if containsReservedField(child, visited) then
            return true
        end
    end
    return false
end

local function arrayRemoveValue(array, value)
    for index, candidate in ipairs(array) do
        if candidate == value then
            table.remove(array, index)
            return true
        end
    end
    return false
end

local function neutralEqual(left, right, visited)
    if type(left) ~= type(right) then
        return false
    end
    if type(left) ~= "table" then
        return left == right
    end
    visited = visited or {}
    if visited[left] ~= nil then
        return visited[left] == right
    end
    visited[left] = right
    for key, value in pairs(left) do
        if not neutralEqual(value, right[key], visited) then
            return false
        end
    end
    for key in pairs(right) do
        if left[key] == nil then
            return false
        end
    end
    return true
end

local function neutralItemCount(value)
    local count = 0
    local seen = {}
    local tasks = {value}
    while #tasks > 0 do
        local current = tasks[#tasks]
        tasks[#tasks] = nil
        count = count + 1
        if type(current) == "table" then
            if getmetatable(current) ~= nil or seen[current] then
                return nil, "invalidNeutralState"
            end
            seen[current] = true
            for _, child in pairs(current) do
                tasks[#tasks + 1] = child
            end
        end
    end
    return count
end

local function normalizeMetadata(value)
    if value == nil then
        value = {}
    end
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        return nil, "invalidMetadataMap"
    end
    local visitedKeys = 0
    for key in next, value do
        visitedKeys = visitedKeys + 1
        if visitedKeys > Constants.LIMITS.maxComponents or type(key) ~= "string" then
            return nil, "invalidMetadataMap"
        end
    end
    local copied, copyError = neutralCopy(value, Constants.LIMITS.maxComponents)
    if copied == nil then
        return nil, copyError
    end
    return copied
end

local function hasReason(value, expected)
    return reasonsContain(value.reasons, expected)
end

local function unresolvedMixedMarker(value)
    local metadata = value.metadata
    if type(metadata) ~= "table" or getmetatable(metadata) ~= nil then
        return nil, "invalidRecordMetadata"
    end
    local visitedKeys = 0
    for key in next, metadata do
        visitedKeys = visitedKeys + 1
        if visitedKeys > Constants.LIMITS.maxComponents or type(key) ~= "string" then
            return nil, "invalidRecordMetadata"
        end
    end
    return value.category == "mixedBoundaryTick"
        or hasReason(value, "mixedBoundaryTick")
        or hasReason(value, "boundaryUnresolved")
        or metadata.mixedBoundary == true
        or metadata.unresolvedMixedBoundary == true
end

local ZERO_CHANGED_APPLICATION_CARRIER_KIND = "zeroChangedApplication"

local ZERO_CHANGED_APPLICATION_OPERATIONS = {
    seed = "seedingPlanting",
    fertilizer = "fertilizer",
    lime = "lime",
    herbicide = "herbicide",
    manure = "manure",
    slurry = "slurry",
    digestate = "digestate"
}

local function zeroChangedApplicationMarker(value, ledger)
    local metadata = value.metadata
    if type(metadata) ~= "table" or getmetatable(metadata) ~= nil then
        return nil, "invalidRecordMetadata"
    end
    if metadata.unallocatedKind ~= ZERO_CHANGED_APPLICATION_CARRIER_KIND then
        return false
    end
    local expectedOperation = ZERO_CHANGED_APPLICATION_OPERATIONS[
        value.category]
    if value.recordType ~= Constants.RECORD_TYPE.Input
        or value.accountingClass ~= Constants.ACCOUNTING_CLASS.Observed
        or expectedOperation == nil
        or value.qualityClass ~= Constants.QUALITY_CLASS.Partial
        or value.unit ~= Constants.UNIT.Litres
        or type(value.amount) ~= "number" or value.amount ~= value.amount
        or value.amount == math.huge or value.amount == -math.huge
        or value.amount <= 0
        or not hasReason(value, "zeroChangedArea")
        or (metadata.attributionKind ~= "baseField"
            and metadata.attributionKind ~= "parcel")
        or metadata.areaEvidence ~= "zeroChanged"
        or value.sessionId == nil
        or metadata.carrierLandKey ~= value.landKey
        or metadata.candidateLandKeys ~= nil then
        return nil, "invalidZeroChangedApplication"
    end
    if ledger ~= nil then
        local session = type(ledger.sessionsById) == "table"
            and ledger.sessionsById[value.sessionId] or nil
        if session == nil or session.cycleId ~= value.cycleId
            or session.landKey ~= value.landKey
            or session.carrierKind ~= ZERO_CHANGED_APPLICATION_CARRIER_KIND
            or session.operationType ~= expectedOperation
            or session.activeMs ~= 0 then
            return nil, "invalidZeroChangedApplicationCarrier"
        end
    end
    return true
end

local function unallocatedRecordMarker(value, ledger)
    local mixed, mixedError = unresolvedMixedMarker(value)
    if mixed == nil then return nil, mixedError end
    local metadata = value.metadata
    local kind = metadata.unallocatedKind
    if kind ~= nil and kind ~= "zeroChangedApplication" then
        return nil, "invalidUnallocatedKind"
    end
    if kind == "zeroChangedApplication" then
        if mixed then return nil, "unallocatedMarkerCollision" end
        local zeroChanged, zeroError = zeroChangedApplicationMarker(
            value, ledger)
        if zeroChanged == nil then return nil, zeroError end
        if not zeroChanged then return nil, "invalidZeroChangedApplication" end
        return true, nil, "zeroChangedApplication"
    end
    if mixed then return true, nil, "mixedBoundary" end
    if rawget(metadata, "unallocated") ~= nil
        or rawget(metadata, "carrierOnly") ~= nil then
        return nil, "reservedUnallocatedFlag"
    end
    return false
end

local function normalizeZeroChangedApplicationMetadata(metadata)
    metadata.unallocated = true
    metadata.carrierOnly = true
    return metadata
end

local function normalizeMixedBoundaryMetadata(metadata, farmId)
    local candidates, candidateError = Core.Validation.array(
        metadata.candidateLandKeys,
        Constants.LIMITS.maxBoundaryCandidates
    )
    if candidates == nil or #candidates == 0 then
        return nil, candidateError or "mixedBoundaryCandidatesRequired"
    end
    local normalized = {}
    local seen = {}
    for _, landKey in ipairs(candidates) do
        local parts, landError = validateLandKey(landKey)
        if parts == nil then
            return nil, landError
        end
        if parts.farmId ~= farmId then
            return nil, "mixedBoundaryFarmMismatch"
        end
        if not seen[landKey] then
            seen[landKey] = true
            normalized[#normalized + 1] = landKey
        end
    end
    table.sort(normalized, byteLess)
    metadata.candidateLandKeys = normalized
    metadata.mixedBoundary = true
    metadata.unallocated = true
    metadata.unresolvedMixedBoundary = nil
    return metadata
end

local function retentionProtection(ledger, cycle)
    local protectedRecords = {}
    local protectedSessions = {}
    for targetId in pairs(ledger.correctionsByTarget) do
        local target = ledger.recordsById[targetId]
        if target ~= nil and target.cycleId == cycle.id then
            protectedRecords[targetId] = true
        end
    end
    for targetId in pairs(ledger.excludedTargets) do
        local record = ledger.recordsById[targetId]
        if record ~= nil and record.cycleId == cycle.id then
            protectedRecords[targetId] = true
        end
        local session = ledger.sessionsById[targetId]
        if session ~= nil and session.cycleId == cycle.id then
            protectedSessions[targetId] = true
        end
    end
    for _, recordId in ipairs(ledger.recordOrder) do
        local record = ledger.recordsById[recordId]
        if record.cycleId == cycle.id then
            local unallocated, markerError = unallocatedRecordMarker(
                record, ledger)
            if unallocated == nil then
                return nil, nil, markerError
            end
            if unallocated
                or record.recordType == Constants.RECORD_TYPE.Valuation
                or record.accountingClass == Constants.ACCOUNTING_CLASS.Direct
                or record.directProvenance ~= nil then
                protectedRecords[recordId] = true
            end
            if record.sessionId ~= nil and protectedSessions[record.sessionId] then
                protectedRecords[recordId] = true
            end
        end
    end
    local changed = true
    while changed do
        changed = false
        for recordId in pairs(protectedRecords) do
            local record = ledger.recordsById[recordId]
            if record ~= nil then
                if record.sessionId ~= nil and not protectedSessions[record.sessionId] then
                    protectedSessions[record.sessionId] = true
                    changed = true
                end
                for _, reference in ipairs(record.references or {}) do
                    if ledger.recordsById[reference] ~= nil
                        and not protectedRecords[reference] then
                        protectedRecords[reference] = true
                        changed = true
                    elseif ledger.sessionsById[reference] ~= nil
                        and not protectedSessions[reference] then
                        protectedSessions[reference] = true
                        changed = true
                    end
                end
            end
        end
    end
    return protectedRecords, protectedSessions
end

local function accumulateCategoryState(states, source, exactState, terms, recordCount)
    local maximum = amountLimitForUnit(source.unit)
    if maximum == nil then
        return nil, "aggregateOutOfRange"
    end
    local exactSum, exactError = exactSumDependency()
    if exactSum == nil then
        return nil, exactError
    end
    local aggregateKey = categoryAggregateKey(source)
    local state = states[aggregateKey]
    if state == nil then
        local accumulator = nil
        accumulator, exactError = exactSum.new(
            maximum,
            Constants.LIMITS.maxRecords
        )
        if accumulator == nil then
            return nil, exactError
        end
        state = {
            accountingClass = source.accountingClass,
            category = source.category,
            unit = source.unit,
            direction = source.direction,
            recordCount = 0,
            accumulator = accumulator,
            maximum = maximum
        }
        states[aggregateKey] = state
    end
    if state.recordCount + recordCount > Constants.LIMITS.maxRecords then
        return nil, "aggregateCountOutOfRange"
    end
    if exactState ~= nil then
        local merged, mergeError = exactSum.merge(state.accumulator, exactState)
        if not merged then
            return nil, mergeError
        end
    else
        for _, term in ipairs(terms or {}) do
            local added, addError = exactSum.add(state.accumulator, term)
            if not added then
                return nil, addError
            end
        end
    end
    state.recordCount = state.recordCount + recordCount
    return true
end

local function finalizeCategoryStates(states)
    local exactSum, exactError = exactSumDependency()
    if exactSum == nil then
        return nil, exactError
    end
    local finalized = {}
    for aggregateKey, state in pairs(states) do
        local amount, finishError = exactSum.finish(
            state.accumulator,
            state.maximum
        )
        if amount == nil or amount < 0 then
            if finishError == nil or finishError == "aggregateOutOfRange" then
                return nil, "categoryTotalOutOfRange"
            end
            return nil, finishError
        end
        local exactState = nil
        exactState, exactError = exactSum.toNeutral(state.accumulator)
        if exactState == nil then
            return nil, exactError
        end
        finalized[aggregateKey] = {
            accountingClass = state.accountingClass,
            category = state.category,
            unit = state.unit,
            direction = state.direction,
            recordCount = state.recordCount,
            exactSum = exactState
        }
    end
    return finalized
end

local function categoryTotalsFromStoredStates(states)
    local exactSum, exactError = exactSumDependency()
    if exactSum == nil then return nil, exactError end
    local totals = {}
    for _, state in pairs(states or {}) do
        local maximum = amountLimitForUnit(state.unit)
        if maximum == nil then return nil, "aggregateOutOfRange" end
        local accumulator
        accumulator, exactError = exactSum.fromNeutral(
            state.exactSum, maximum, Constants.LIMITS.maxRecords)
        if accumulator == nil then return nil, exactError end
        local amount, finishError = exactSum.finish(accumulator, maximum)
        if amount == nil or amount < 0 then
            return nil, finishError or "categoryTotalOutOfRange"
        end
        totals[#totals + 1] = {
            accountingClass=state.accountingClass, category=state.category,
            unit=state.unit, direction=state.direction,
            recordCount=state.recordCount, amount=amount
        }
    end
    table.sort(totals, function(left, right)
        if left.accountingClass ~= right.accountingClass then
            return byteLess(left.accountingClass, right.accountingClass)
        end
        if left.category ~= right.category then
            return byteLess(left.category, right.category)
        end
        if left.unit ~= right.unit then return byteLess(left.unit, right.unit) end
        return byteLess(left.direction or "", right.direction or "")
    end)
    return totals
end

-- Active runtime segments are deliberately not canonical records.  They are
-- folded into presentation totals only, so a one-second GUI refresh does not
-- turn a continuous AI job into hundreds of ledger rows.  Canonical export
-- and persistence callers opt out with includeLive=false.
local function categoryTotalsWithLive(ledger, cycleId, totals)
    local keys = ledger._liveFactKeysByCycle[cycleId]
    if type(keys) ~= "table" or next(keys) == nil then return totals end
    local exactSum, exactError = exactSumDependency()
    if exactSum == nil then return nil, exactError end
    local byKey = {}
    for _, total in ipairs(totals) do
        byKey[categoryAggregateKey(total)] = total
    end
    local orderedKeys = {}
    for key in pairs(keys) do orderedKeys[#orderedKeys + 1] = key end
    table.sort(orderedKeys, byteLess)
    for _, key in ipairs(orderedKeys) do
        local fact = ledger._liveFactsByKey[key]
        if fact ~= nil and fact.cycleId == cycleId then
            local aggregateKey = categoryAggregateKey(fact)
            local total = byKey[aggregateKey]
            if total == nil then
                total = {
                    accountingClass=fact.accountingClass,
                    category=fact.category, unit=fact.unit,
                    direction=fact.direction, recordCount=0, amount=0
                }
                totals[#totals + 1] = total
                byKey[aggregateKey] = total
            end
            local maximum = amountLimitForUnit(fact.unit)
            if maximum == nil then return nil, "aggregateOutOfRange" end
            local accumulator
            accumulator, exactError = exactSum.new(
                maximum, Constants.LIMITS.maxRecords)
            if accumulator == nil then return nil, exactError end
            local added, addError = exactSum.add(accumulator, total.amount)
            if not added then return nil, addError end
            added, addError = exactSum.add(accumulator, fact.amount)
            if not added then return nil, addError end
            local amount, finishError = exactSum.finish(accumulator, maximum)
            if amount == nil or amount < 0 then
                return nil, finishError or "categoryTotalOutOfRange"
            end
            total.amount = amount
        end
    end
    table.sort(totals, function(left, right)
        if left.accountingClass ~= right.accountingClass then
            return byteLess(left.accountingClass, right.accountingClass)
        end
        if left.category ~= right.category then
            return byteLess(left.category, right.category)
        end
        if left.unit ~= right.unit then return byteLess(left.unit, right.unit) end
        return byteLess(left.direction or "", right.direction or "")
    end)
    return totals
end

local function buildCategoryStates(
    ledger,
    cycleId,
    retentionSummaryOverride,
    pendingExclusionTarget
)
    local cycle = ledger.cyclesById[cycleId]
    if cycle == nil then
        return nil, "unknownCycle"
    end
    local states = {}
    local retentionSummary = retentionSummaryOverride or cycle.retentionSummary
    if retentionSummary ~= nil then
        for _, entry in ipairs(retentionSummary.entries) do
            if entry.exactSum ~= nil then
                local accumulated, aggregateError = accumulateCategoryState(
                    states,
                    entry,
                    entry.exactSum,
                    nil,
                    entry.sourceRecordCount
                )
                if not accumulated then
                    return nil, aggregateError
                end
            end
        end
    end
    for _, recordId in ipairs(ledger.recordOrder) do
        local record = ledger.recordsById[recordId]
        if record.cycleId == cycleId and record.amount ~= nil then
            local excluded = ledger.excludedTargets[record.id] ~= nil
                or (record.sessionId ~= nil
                    and ledger.excludedTargets[record.sessionId] ~= nil)
                or pendingExclusionTarget == record.id
                or (record.sessionId ~= nil
                    and pendingExclusionTarget == record.sessionId)
            local unallocated, markerError = unallocatedRecordMarker(
                record, ledger)
            if unallocated == nil then
                return nil, markerError
            end
            if not excluded and not unallocated then
                local terms = {record.amount}
                for _, correctionId in ipairs(
                    ledger.correctionsByTarget[record.id] or {}
                ) do
                    local correction = ledger.correctionsById[correctionId]
                    if correction == nil then
                        return nil, "danglingCorrection"
                    end
                    terms[#terms + 1] = correction.delta
                end
                local accumulated, aggregateError = accumulateCategoryState(
                    states,
                    record,
                    nil,
                    terms,
                    1
                )
                if not accumulated then
                    return nil, aggregateError
                end
            end
        end
    end
    return finalizeCategoryStates(states)
end

function Ledger.new(options)
    options = options or {}
    if type(options) ~= "table" then
        return nil, "invalidOptions"
    end
    if options.calendarYearSupported ~= nil and type(options.calendarYearSupported) ~= "boolean" then
        return nil, "invalidCalendarYearSupport"
    end
    local epoch, epochError = validateInteger(options.epoch or 1, 1, Constants.LIMITS.maxIdentifier)
    if epoch == nil then
        return nil, epochError
    end
    local nextId, idError = validateInteger(options.nextId or 1, 1, Constants.LIMITS.maxRecords + 1)
    if nextId == nil then
        return nil, idError
    end
    local neutralItemLimit = nil
    neutralItemLimit, idError = validateInteger(
        options.neutralItemLimit or Constants.LIMITS.maxLedgerNeutralItems,
        1,
        Constants.LIMITS.maxLedgerNeutralItems
    )
    if neutralItemLimit == nil then
        return nil, idError
    end

    local self = setmetatable({}, Ledger)
    self.schemaVersion = Constants.SCHEMA_VERSION
    self.epoch = epoch
    self.nextId = nextId
    self.cyclesById = {}
    self.cycleOrder = {}
    self.openCycleByLand = {}
    self.lastCycleByLand = {}
    self.sessionsById = {}
    self.sessionOrder = {}
    self.openSessionByContext = {}
    self.openSessionByRoot = {}
    self.contextKeyBySession = {}
    self.rootKeyBySession = {}
    self.lastEvidenceSequenceBySession = {}
    self.lastEvidencePayloadBySession = {}
    self.lastEvidenceSequenceByRoot = {}
    self.lastEvidencePayloadByRoot = {}
    self.lastActivityTimeByCycle = {}
    self.recordsById = {}
    self.recordOrder = {}
    self.observationIndex = {}
    self.directTransactionIndex = {}
    self.correctionsById = {}
    self.correctionOrder = {}
    self.correctionsByTarget = {}
    self.exclusionsById = {}
    self.exclusionOrder = {}
    self.excludedTargets = {}
    self.aliases = {}
    self.groups = {}
    self.categoryStatesByCycle = {}
    -- Ephemeral report indexes. They are deliberately absent from neutral
    -- persistence so savegame bytes and schema remain unchanged.
    self._reportRevision = 0
    self._cycleRevisionById = {}
    self._canonicalReportRevision = 0
    self._canonicalCycleRevisionById = {}
    self._liveFactsByKey = {}
    self._liveFactKeysByCycle = {}
    self._recordIdsByCycle = {}
    self._includedRecordIdsByCycle = {}
    self._cycleBoundaryEvidenceByCycle = {}
    self._correctionIdsByCycle = {}
    self._exclusionIdsByCycle = {}
    self._queryStateByCycle = {}
    -- Active-session segment state is deliberately transient. Repeated engine
    -- update callbacks extend one canonical record per semantic segment; only
    -- that exact aggregate is persisted when the session closes or saves.
    self._segmentStatesByKey = {}
    self._segmentKeysBySession = {}
    -- A constant-size high-water row owns each semantic observation stream for
    -- this ledger epoch.  A row is created only with a successfully allocated
    -- segment record, so the record-ID ceiling also bounds the row count.  This
    -- prevents folded IDs from being reused without retaining every callback
    -- ID.  The rows need not be serialized: fromNeutral rotates the epoch
    -- before accepting new evidence.
    self._segmentObservationStreamsByKey = {}
    self._segmentStreamKeyByRecordId = {}
    self.settings = {
        retentionMode = Constants.RETENTION_MODE.All,
        calendarYearSupported = options.calendarYearSupported == true
    }
    self.loadDiagnostics = {}
    self.neutralItemLimit = neutralItemLimit
    local initialDocument = {
        schemaVersion = self.schemaVersion,
        epoch = self.epoch,
        nextId = self.nextId,
        cycles = {},
        sessions = {},
        records = {},
        corrections = {},
        exclusions = {},
        aliases = {},
        groups = {},
        settings = self.settings
    }
    local initialItems = neutralItemCount(initialDocument)
    if initialItems == nil or initialItems > self.neutralItemLimit then
        return nil, "ledgerNeutralBudgetExceeded"
    end
    self._neutralItems = initialItems
    return self
end

local function clearSegmentReplay(stream)
    stream.firstObservationId = nil
    stream.firstEvent = nil
    stream.lastObservationId = nil
    stream.lastEvent = nil
end

local function clearSegmentState(ledger, sessionId)
    local keys = ledger._segmentKeysBySession[sessionId]
    if type(keys) == "table" then
        for _, key in ipairs(keys) do
            local state = ledger._segmentStatesByKey[key]
            local stream = type(state) == "table"
                and ledger._segmentObservationStreamsByKey[state.streamKey]
                or nil
            if stream ~= nil
                and stream.recordId == state.recordId
                and stream.sessionId == sessionId
                and stream.segmentKey == key
                and ledger._segmentStreamKeyByRecordId[state.recordId]
                    == state.streamKey then
                -- Keep only the current stream owner's exact endpoint events.
                -- Folded middle callbacks remain represented by the high-water
                -- sequence and fail closed, without per-callback identity
                -- growth.  Epoch rotation invalidates all transient snapshots.
                stream.firstObservationId = state.firstObservationId
                stream.firstEvent = state.firstEvent
                stream.lastObservationId = state.lastObservationId
                stream.lastEvent = state.lastEvent
            end
            ledger._segmentStatesByKey[key] = nil
        end
    end
    ledger._segmentKeysBySession[sessionId] = nil
end

local function clearSegmentObservationOwnership(ledger, recordId)
    local streamKey = ledger._segmentStreamKeyByRecordId[recordId]
    local stream = streamKey ~= nil
        and ledger._segmentObservationStreamsByKey[streamKey] or nil
    if stream ~= nil and stream.recordId == recordId then
        -- Keep the sequence tombstone until epoch rotation so deleting the
        -- current owner cannot make one of its folded observation IDs reusable.
        clearSegmentReplay(stream)
        stream.recordId = nil
        stream.sessionId = nil
        stream.segmentKey = nil
    end
    ledger._segmentStreamKeyByRecordId[recordId] = nil
end

local function clearCycleSegmentReplay(ledger, cycleId)
    for _, recordId in ipairs(ledger._recordIdsByCycle[cycleId] or {}) do
        local streamKey = ledger._segmentStreamKeyByRecordId[recordId]
        local stream = streamKey ~= nil
            and ledger._segmentObservationStreamsByKey[streamKey] or nil
        if stream ~= nil and stream.recordId == recordId then
            -- A closed cycle is rejected before record replay is considered.
            -- Preserve stream ownership/high-water collision protection for a
            -- later cycle, but release endpoint payloads that are now
            -- unreachable.
            clearSegmentReplay(stream)
        end
    end
end

local function segmentObservationStreamKey(observationParts)
    return lengthPrefixed({
        observationParts.vehicleUniqueId,
        observationParts.discriminator
    })
end

function Ledger:_prepareCategoryDelta(source, terms, recordDelta)
    local cycleId = source.cycleId
    if self.cyclesById[cycleId] == nil then
        return nil, nil, "unknownCycle"
    end
    local states = self.categoryStatesByCycle[cycleId]
    local rebuiltStates = nil
    if states == nil then
        local rebuildError = nil
        states, rebuildError = buildCategoryStates(self, cycleId)
        if states == nil then
            return nil, nil, rebuildError
        end
        rebuiltStates = states
    end
    local aggregateKey = categoryAggregateKey(source)
    local existing = states[aggregateKey]
    local maximum = amountLimitForUnit(source.unit)
    if maximum == nil then
        return nil, nil, "aggregateOutOfRange"
    end
    local exactSum, exactError = exactSumDependency()
    if exactSum == nil then
        return nil, nil, exactError
    end
    local accumulator = nil
    local recordCount = 0
    if existing ~= nil then
        accumulator, exactError = exactSum.fromNeutral(
            existing.exactSum,
            maximum,
            Constants.LIMITS.maxRecords
        )
        if accumulator == nil then
            return nil, nil, exactError
        end
        recordCount = existing.recordCount
    else
        accumulator, exactError = exactSum.new(
            maximum,
            Constants.LIMITS.maxRecords
        )
        if accumulator == nil then
            return nil, nil, exactError
        end
    end
    local proposedCount = recordCount + recordDelta
    if proposedCount < 0 or proposedCount > Constants.LIMITS.maxRecords then
        return nil, nil, "aggregateCountOutOfRange"
    end
    for _, term in ipairs(terms) do
        local added, addError = exactSum.add(accumulator, term)
        if not added then
            return nil, nil, addError
        end
    end
    local amount, finishError = exactSum.finish(accumulator, maximum)
    if amount == nil or amount < 0 then
        if finishError == nil or finishError == "aggregateOutOfRange" then
            return nil, nil, "categoryTotalOutOfRange"
        end
        return nil, nil, finishError
    end
    local exactState = nil
    exactState, exactError = exactSum.toNeutral(accumulator)
    if exactState == nil then
        return nil, nil, exactError
    end
    return aggregateKey, {
        accountingClass = source.accountingClass,
        category = source.category,
        unit = source.unit,
        direction = source.direction,
        recordCount = proposedCount,
        exactSum = exactState
    }, rebuiltStates
end

function Ledger:_commitCategoryState(cycleId, aggregateKey, state, rebuiltStates)
    if self.categoryStatesByCycle[cycleId] == nil then
        self.categoryStatesByCycle[cycleId] = rebuiltStates or {}
    end
    self.categoryStatesByCycle[cycleId][aggregateKey] = state
end

function Ledger:_preflightNeutralDelta(delta)
    if type(delta) ~= "number" or delta ~= math.floor(delta) then
        return nil, "invalidNeutralBudgetDelta"
    end
    if self._neutralItems + delta > self.neutralItemLimit then
        return nil, "ledgerNeutralBudgetExceeded"
    end
    if self._neutralItems + delta < 1 then
        return nil, "invalidNeutralBudgetDelta"
    end
    return true
end

function Ledger:_commitNeutralDelta(delta)
    self._neutralItems = self._neutralItems + delta
end

function Ledger:_replacementNeutralDelta(before, after)
    local beforeCount, countError = neutralItemCount(before)
    if beforeCount == nil then
        return nil, countError
    end
    local afterCount = nil
    afterCount, countError = neutralItemCount(after)
    if afterCount == nil then
        return nil, countError
    end
    return afterCount - beforeCount
end

function Ledger:_allocateId(kind)
    local id, idError = self:_previewId(kind)
    if id == nil then
        return nil, idError
    end
    self.nextId = self.nextId + 1
    return id
end

function Ledger:_previewId(kind)
    local _, identifiers, dependencyError = dependencies()
    if dependencyError ~= nil then
        return nil, dependencyError
    end
    if self.nextId > Constants.LIMITS.maxRecords then
        return nil, "recordLimitExceeded"
    end
    local id, idError = identifiers.recordId(kind, self.nextId)
    if id == nil then
        return nil, idError
    end
    return id
end

function Ledger:_copyForCaller(value)
    return neutralCopy(value)
end

function Ledger:_touchReport(cycleId)
    if self._loadingNeutral == true then return end
    self._reportRevision = self._reportRevision + 1
    self._canonicalReportRevision = self._canonicalReportRevision + 1
    if cycleId ~= nil then
        self._cycleRevisionById[cycleId] =
            (self._cycleRevisionById[cycleId] or 0) + 1
        self._canonicalCycleRevisionById[cycleId] =
            (self._canonicalCycleRevisionById[cycleId] or 0) + 1
    end
end

function Ledger:_touchLiveReport(cycleId)
    if self._loadingNeutral == true then return end
    self._reportRevision = self._reportRevision + 1
    if cycleId ~= nil then
        self._cycleRevisionById[cycleId] =
            (self._cycleRevisionById[cycleId] or 0) + 1
    end
end

function Ledger:getReportRevision()
    return self._reportRevision
end

function Ledger:getCycleRevision(cycleId)
    if self.cyclesById[cycleId] == nil then return nil, "unknownCycle" end
    return self._cycleRevisionById[cycleId] or 0
end

function Ledger:getCanonicalReportRevision()
    return self._canonicalReportRevision
end

function Ledger:getCanonicalCycleRevision(cycleId)
    if self.cyclesById[cycleId] == nil then return nil, "unknownCycle" end
    return self._canonicalCycleRevisionById[cycleId] or 0
end

local function validLiveKey(value)
    if type(value) ~= "string" or #value == 0 or #value > 256 then return false end
    for index = 1, #value do
        local byte = string.byte(value, index)
        if byte < 33 or byte > 126 then return false end
    end
    return true
end

function Ledger:setLiveFact(key, fact)
    if not validLiveKey(key) or type(fact) ~= "table"
        or getmetatable(fact) ~= nil then return nil, "invalidLiveFact" end
    local cycleId = rawget(fact, "cycleId")
    local category = rawget(fact, "category")
    local amount = rawget(fact, "amount")
    local accountingClass = rawget(fact, "accountingClass")
    local unit = rawget(fact, "unit")
    local direction = rawget(fact, "direction")
    local observedTime = accountingClass == Constants.ACCOUNTING_CLASS.Observed
        and (category == Constants.CATEGORY.aiLabourTime
            or category == Constants.CATEGORY.workingTime)
        and unit == Constants.UNIT.Milliseconds and direction == nil
    local directCost = accountingClass == Constants.ACCOUNTING_CLASS.Direct
        and category == Constants.CATEGORY.directObservedCost
        and unit == Constants.UNIT.Money
        and direction == Constants.DIRECTION.Expense
    local maximum = amountLimitForUnit(unit)
    if self.cyclesById[cycleId] == nil
        or (not observedTime and not directCost)
        or type(amount) ~= "number" or amount ~= amount
        or amount == math.huge or amount == -math.huge or amount <= 0
        or maximum == nil or amount > maximum then
        return nil, "invalidLiveFact"
    end
    local normalized = {cycleId=cycleId,
        accountingClass=accountingClass,
        category=category, amount=amount,
        unit=unit, direction=direction}
    local previous = self._liveFactsByKey[key]
    if previous ~= nil and previous.cycleId == normalized.cycleId
        and previous.accountingClass == normalized.accountingClass
        and previous.category == normalized.category
        and previous.amount == normalized.amount
        and previous.unit == normalized.unit then return true, false end
    if previous ~= nil then
        local oldKeys = self._liveFactKeysByCycle[previous.cycleId]
        if oldKeys ~= nil then oldKeys[key] = nil end
        self:_touchLiveReport(previous.cycleId)
    end
    self._liveFactsByKey[key] = normalized
    local cycleKeys = self._liveFactKeysByCycle[cycleId]
    if cycleKeys == nil then
        cycleKeys = {}
        self._liveFactKeysByCycle[cycleId] = cycleKeys
    end
    cycleKeys[key] = true
    self:_touchLiveReport(cycleId)
    return true, true
end

function Ledger:clearLiveFact(key)
    if not validLiveKey(key) then return nil, "invalidLiveFactKey" end
    local previous = self._liveFactsByKey[key]
    if previous == nil then return true, false end
    self._liveFactsByKey[key] = nil
    local keys = self._liveFactKeysByCycle[previous.cycleId]
    if keys ~= nil then
        keys[key] = nil
        if next(keys) == nil then self._liveFactKeysByCycle[previous.cycleId] = nil end
    end
    self:_touchLiveReport(previous.cycleId)
    return true, true
end

local function boundaryHarvestIsNewer(evidence, missionTime, recordId)
    if not evidence.hasHarvest
            or type(evidence.lastHarvestMissionTime) ~= "number"
            or type(evidence.lastHarvestRecordId) ~= "string" then
        return true
    end
    if missionTime ~= evidence.lastHarvestMissionTime then
        return missionTime > evidence.lastHarvestMissionTime
    end
    local _, identifiers = dependencies()
    return identifiers.compare(recordId, evidence.lastHarvestRecordId) > 0
end

function Ledger:_rebuildCycleQueryIndexes(cycleId)
    if self.cyclesById[cycleId] == nil then return nil, "unknownCycle" end
    local all, included = {}, {}
    local boundaryEvidence = {
        hasHarvest = false,
        lastActivityMissionTime = self.lastActivityTimeByCycle[cycleId]
    }
    local qualityCounts = {
        [Constants.QUALITY_CLASS.Complete]=0,
        [Constants.QUALITY_CLASS.Partial]=0,
        [Constants.QUALITY_CLASS.Unsupported]=0
    }
    local basisClasses, overlap = {}, false
    for _, recordId in ipairs(self.recordOrder) do
        local record = self.recordsById[recordId]
        if record ~= nil and record.cycleId == cycleId then
            all[#all + 1] = recordId
            local excluded = self.excludedTargets[record.id] ~= nil
                or (record.sessionId ~= nil
                    and self.excludedTargets[record.sessionId] ~= nil)
            if not excluded then
                included[#included + 1] = recordId
                local unallocated, markerError = unallocatedRecordMarker(
                    record, self)
                if unallocated == nil then return nil, markerError end
                if record.recordType == Constants.RECORD_TYPE.Harvest
                        and record.category == Constants.CATEGORY.harvest
                        and not unallocated
                        and boundaryHarvestIsNewer(
                            boundaryEvidence, record.missionTime,
                            record.id) then
                    boundaryEvidence.hasHarvest = true
                    boundaryEvidence.lastHarvestMissionTime = record.missionTime
                    boundaryEvidence.lastHarvestRecordId = record.id
                end
                qualityCounts[record.qualityClass] =
                    (qualityCounts[record.qualityClass] or 0) + 1
                if not unallocated and record.basisId ~= nil
                    and (record.accountingClass == Constants.ACCOUNTING_CLASS.Direct
                        or record.accountingClass == Constants.ACCOUNTING_CLASS.Valued) then
                    local classes = basisClasses[record.basisId] or {}
                    classes[record.accountingClass] = true
                    basisClasses[record.basisId] = classes
                    if classes[Constants.ACCOUNTING_CLASS.Direct]
                        and classes[Constants.ACCOUNTING_CLASS.Valued] then
                        overlap = true
                    end
                end
            end
        end
    end
    local corrections = {}
    for _, id in ipairs(self.correctionOrder) do
        local correction = self.correctionsById[id]
        local target = correction and self.recordsById[correction.targetId]
        if target ~= nil and target.cycleId == cycleId then
            corrections[#corrections + 1] = id
        end
    end
    local exclusions = {}
    for _, id in ipairs(self.exclusionOrder) do
        local exclusion = self.exclusionsById[id]
        local target = exclusion and (self.recordsById[exclusion.targetId]
            or self.sessionsById[exclusion.targetId])
        if target ~= nil and target.cycleId == cycleId then
            exclusions[#exclusions + 1] = id
        end
    end
    self._recordIdsByCycle[cycleId] = all
    self._includedRecordIdsByCycle[cycleId] = included
    self._cycleBoundaryEvidenceByCycle[cycleId] = boundaryEvidence
    self._correctionIdsByCycle[cycleId] = corrections
    self._exclusionIdsByCycle[cycleId] = exclusions
    self._queryStateByCycle[cycleId] = {
        qualityCounts=qualityCounts, directReplacementOverlap=overlap,
        basisClasses=basisClasses
    }
    return true
end

function Ledger:_rebuildAllQueryIndexes()
    self._recordIdsByCycle, self._includedRecordIdsByCycle = {}, {}
    self._cycleBoundaryEvidenceByCycle = {}
    self._correctionIdsByCycle, self._exclusionIdsByCycle = {}, {}
    self._queryStateByCycle = {}
    for _, cycleId in ipairs(self.cycleOrder) do
        local ok, reason = self:_rebuildCycleQueryIndexes(cycleId)
        if not ok then return nil, reason end
    end
    return true
end

function Ledger:openCycle(command)
    if type(command) ~= "table" then
        return nil, "invalidCommand"
    end
    local landParts, landError = validateLandKey(command.landKey)
    if landParts == nil then
        return nil, landError
    end
    if self.openCycleByLand[command.landKey] ~= nil then
        return nil, "cycleAlreadyOpen"
    end
    local fruitType, fruitError = validateToken(command.fruitType or "unknown")
    if fruitType == nil then
        return nil, fruitError
    end
    local period, periodError = validateInteger(command.period, 1, Constants.LIMITS.maxPeriod)
    if period == nil then
        return nil, periodError
    end
    local missionTime, timeError = validateMissionTime(command.missionTime)
    if missionTime == nil then
        return nil, timeError
    end
    local year = nil
    local yearQuality = Constants.QUALITY_CLASS.Unsupported
    local yearReason = "calendarYearUnavailable"
    if command.year ~= nil then
        if self.settings.calendarYearSupported ~= true then
            return nil, "calendarYearUnsupported"
        end
        year, yearReason = validateInteger(command.year, 0, Constants.LIMITS.maxYear)
        if year == nil then
            return nil, yearReason
        end
        yearQuality = Constants.QUALITY_CLASS.Complete
        yearReason = nil
    end
    local fruitTypeId = nil
    local fruitIdError = nil
    if command.fruitTypeId ~= nil then
        fruitTypeId, fruitIdError = validateInteger(command.fruitTypeId, 0, Constants.LIMITS.maxIdentifier)
        if fruitTypeId == nil then
            return nil, fruitIdError
        end
    end
    local fillTypeId = nil
    if command.fillTypeId ~= nil then
        fillTypeId, fruitIdError = validateInteger(command.fillTypeId, 0, Constants.LIMITS.maxIdentifier)
        if fillTypeId == nil then
            return nil, fruitIdError
        end
    end
    local qualityClass = command.qualityClass or Constants.QUALITY_CLASS.Complete
    if not Constants.QUALITY_CLASS_SET[qualityClass] then
        return nil, "invalidQualityClass"
    end
    local reasons, reasonsError = normalizeReasons(command.reasons)
    if reasons == nil then
        return nil, reasonsError
    end
    local conservativeReasons = {}
    if fruitType == "unknown" then
        conservativeReasons[#conservativeReasons + 1] = "cropUnknown"
        qualityClass = lowerQuality(qualityClass, Constants.QUALITY_CLASS.Partial)
    end
    if landParts.fieldKind == "parcel" then
        conservativeReasons[#conservativeReasons + 1] = "parcelFallback"
        qualityClass = lowerQuality(qualityClass, Constants.QUALITY_CLASS.Partial)
    end
    reasons, reasonsError = mergeReasons(reasons, conservativeReasons)
    if reasons == nil then
        return nil, reasonsError
    end
    if qualityClass ~= Constants.QUALITY_CLASS.Complete and #reasons == 0 then
        return nil, "qualityReasonRequired"
    end
    local cycleAreaHa = nil
    if command.cycleAreaHa ~= nil then
        cycleAreaHa, timeError = validateNumber(
            command.cycleAreaHa,
            0,
            Constants.LIMITS.maxAreaHa
        )
        if cycleAreaHa == nil then
            return nil, timeError
        end
        if cycleAreaHa == 0 then
            return nil, "belowMinimum"
        end
    end
    local previousCycleId = self.lastCycleByLand[command.landKey]
    local previousCycle = previousCycleId and self.cyclesById[previousCycleId] or nil
    if previousCycle ~= nil then
        if previousCycle.state == Constants.CYCLE_STATE.Open then
            return nil, "cycleAlreadyOpen"
        end
        if previousCycle.endMissionTime ~= nil and missionTime < previousCycle.endMissionTime then
            return nil, "timeBeforePreviousCycle"
        end
        if previousCycle.endYear ~= nil and year ~= nil then
            if year < previousCycle.endYear
                or (year == previousCycle.endYear
                    and period < previousCycle.endPeriod) then
                return nil, "calendarBeforePreviousCycle"
            end
        end
    end
    local id, idError = self:_previewId("cycle")
    if id == nil then
        return nil, idError
    end
    local cycle = {
        id = id,
        landKey = command.landKey,
        farmId = landParts.farmId,
        farmlandId = landParts.farmlandId,
        fieldId = landParts.fieldId,
        fieldKind = landParts.fieldKind,
        fruitType = fruitType,
        fruitTypeId = fruitTypeId,
        fillTypeId = fillTypeId,
        state = Constants.CYCLE_STATE.Open,
        startPeriod = period,
        startMissionTime = missionTime,
        startYear = year,
        calendarYearQuality = yearQuality,
        calendarYearReason = yearReason,
        cycleAreaHa = cycleAreaHa,
        qualityClass = qualityClass,
        reasons = reasons
    }
    local cycleItems, countError = neutralItemCount(cycle)
    if cycleItems == nil then
        return nil, countError
    end
    local budgeted, budgetError = self:_preflightNeutralDelta(cycleItems)
    if not budgeted then
        return nil, budgetError
    end
    local allocatedId = nil
    allocatedId, idError = self:_allocateId("cycle")
    if allocatedId == nil then
        return nil, idError
    end
    if allocatedId ~= id then
        return nil, "identifierAllocationChanged"
    end
    self.cyclesById[id] = cycle
    self.cycleOrder[#self.cycleOrder + 1] = id
    self.openCycleByLand[command.landKey] = id
    self.lastCycleByLand[command.landKey] = id
    self.lastActivityTimeByCycle[id] = missionTime
    self._recordIdsByCycle[id] = {}
    self._includedRecordIdsByCycle[id] = {}
    self._cycleBoundaryEvidenceByCycle[id] = {
        hasHarvest = false,
        lastActivityMissionTime = command.startMissionTime
    }
    self._correctionIdsByCycle[id] = {}
    self._exclusionIdsByCycle[id] = {}
    self._queryStateByCycle[id] = {qualityCounts={
        [Constants.QUALITY_CLASS.Complete]=0,
        [Constants.QUALITY_CLASS.Partial]=0,
        [Constants.QUALITY_CLASS.Unsupported]=0}, directReplacementOverlap=false,
        basisClasses={}}
    self:_commitNeutralDelta(cycleItems)
    self:_touchReport(id)
    return self:_copyForCaller(cycle)
end

function Ledger:getCycle(cycleId)
    local cycle = self.cyclesById[cycleId]
    if cycle == nil then
        return nil, "unknownCycle"
    end
    return self:_copyForCaller(cycle)
end

-- FS25's mission clock restarts when a savegame is loaded. Runtime adapters
-- use this persisted floor to continue on one monotonic ledger timeline
-- without rewriting historical audit timestamps.
function Ledger:getMissionTimeFloor()
    local maximum = 0
    local function include(value)
        if type(value) == "number" and value == value
            and value ~= math.huge and value ~= -math.huge
            and value > maximum then
            maximum = value
        end
    end
    for _, id in ipairs(self.cycleOrder) do
        local value = self.cyclesById[id]
        include(value.startMissionTime)
        include(value.endMissionTime)
        include(self.lastActivityTimeByCycle[id])
    end
    for _, id in ipairs(self.sessionOrder) do
        local value = self.sessionsById[id]
        include(value.firstEvidenceTime)
        include(value.lastEvidenceTime)
    end
    for _, id in ipairs(self.recordOrder) do
        include(self.recordsById[id].missionTime)
    end
    for _, id in ipairs(self.correctionOrder) do
        include(self.correctionsById[id].missionTime)
    end
    for _, id in ipairs(self.exclusionOrder) do
        include(self.exclusionsById[id].missionTime)
    end
    return maximum
end

function Ledger:getRecord(recordId)
    local record = self.recordsById[recordId]
    if record == nil then
        return nil, "unknownRecord"
    end
    return self:_copyForCaller(record)
end

function Ledger:getCycleBoundaryEvidence(cycleId)
    local cycle = self.cyclesById[cycleId]
    if cycle == nil then
        return nil, "unknownCycle"
    end
    if self._includedRecordIdsByCycle[cycleId] == nil
            or self._cycleBoundaryEvidenceByCycle[cycleId] == nil then
        local rebuilt, reason = self:_rebuildCycleQueryIndexes(cycleId)
        if not rebuilt then
            return nil, reason
        end
    end
    self._cycleBoundaryEvidenceByCycle[cycleId].lastActivityMissionTime =
        self.lastActivityTimeByCycle[cycleId]
    return self:_copyForCaller(self._cycleBoundaryEvidenceByCycle[cycleId])
end

function Ledger:listCycles(options)
    if options ~= nil
        and validateKnownFields(
            options,
            LIST_CYCLE_OPTION_KEYS,
            "invalidOptions"
        ) == nil then
        return nil, "invalidOptions"
    end
    options = options or {}

    local farmId = nil
    if options.farmId ~= nil then
        farmId = validateInteger(
            options.farmId,
            1,
            Constants.LIMITS.maxIdentifier
        )
        if farmId == nil then
            return nil, "invalidOptions"
        end
    end

    local landKey = options.landKey
    if landKey ~= nil and validateLandKey(landKey) == nil then
        return nil, "invalidOptions"
    end

    local state = options.state
    if state ~= nil and Constants.CYCLE_STATE_SET[state] ~= true then
        return nil, "invalidOptions"
    end
    local states = options.states
    local stateSet = nil
    if states ~= nil then
        if state ~= nil then
            return nil, "invalidOptions"
        end
        local accepted, arrayError = Core.Validation.array(states, 3)
        if accepted == nil or #accepted == 0 then
            return nil, arrayError or "invalidOptions"
        end
        stateSet = {}
        for _, candidate in ipairs(accepted) do
            if Constants.CYCLE_STATE_SET[candidate] ~= true
                or stateSet[candidate] == true then
                return nil, "invalidOptions"
            end
            stateSet[candidate] = true
        end
    end
    local fieldGrouped = options.fieldGrouped
    if fieldGrouped ~= nil and type(fieldGrouped) ~= "boolean" then
        return nil, "invalidOptions"
    end

    local newestFirst = options.newestFirst
    if newestFirst == nil then
        newestFirst = true
    elseif type(newestFirst) ~= "boolean" then
        return nil, "invalidOptions"
    end

    local offset = options.offset or 0
    offset = validateInteger(offset, 0, Constants.LIMITS.maxRecords)
    if offset == nil then
        return nil, "invalidOptions"
    end
    local limit = options.limit
    if limit == nil then
        limit = Constants.LIMITS.maxQueryRows
    end
    limit = validateInteger(limit, 0, Constants.LIMITS.maxQueryRows)
    if limit == nil then
        return nil, "invalidOptions"
    end

    local matching = {}
    local startIndex = newestFirst and #self.cycleOrder or 1
    local endIndex = newestFirst and 1 or #self.cycleOrder
    local step = newestFirst and -1 or 1
    for index = startIndex, endIndex, step do
        local cycleId = self.cycleOrder[index]
        local cycle = self.cyclesById[cycleId]
        if cycle == nil then
            return nil, "cycleIndexCorrupt"
        end
        if (farmId == nil or cycle.farmId == farmId)
            and (landKey == nil or cycle.landKey == landKey)
            and (state == nil or cycle.state == state)
            and (stateSet == nil or stateSet[cycle.state] == true) then
            matching[#matching + 1] = cycle
        end
    end
    if fieldGrouped == true then
        table.sort(matching, function(left, right)
            if left.landKey ~= right.landKey then
                return byteLess(left.landKey, right.landKey)
            end
            if left.startMissionTime ~= right.startMissionTime then
                if newestFirst then
                    return left.startMissionTime > right.startMissionTime
                end
                return left.startMissionTime < right.startMissionTime
            end
        local _, identifiers = dependencies()
        local compared = identifiers.compare(left.id, right.id)
        if newestFirst then
            return compared > 0
        end
        return compared < 0
        end)
    end
    local rows = {}
    local matchingCount = #matching
    local last = math.min(matchingCount, offset + limit)
    for index = offset + 1, last do
        rows[#rows + 1] = self:_copyForCaller(matching[index])
    end

    local nextOffset = nil
    if limit > 0 and offset + #rows < matchingCount then
        nextOffset = offset + #rows
    end
    local fieldGroupContinuesFromPreviousPage = false
    if fieldGrouped == true and offset > 0 and #rows > 0 then
        local previous = matching[offset]
        local current = matching[offset + 1]
        fieldGroupContinuesFromPreviousPage =
            previous ~= nil and current ~= nil
            and previous.landKey == current.landKey
    end
    return {
        cycles = rows,
        page = {
            offset = offset,
            limit = limit,
            total = matchingCount,
            nextOffset = nextOffset,
            fieldGroupContinuesFromPreviousPage =
                fieldGroupContinuesFromPreviousPage
        }
    }
end

function Ledger:listLegacyClosureCandidates(options)
    options = options or {}
    if type(options) ~= "table" or getmetatable(options) ~= nil then
        return nil, "invalidOptions"
    end
    for key in pairs(options) do
        if key ~= "farmId" and key ~= "limit" and key ~= "offset" then
            return nil, "invalidOptions"
        end
    end
    local offset = validateInteger(
        options.offset or 0, 0, Constants.LIMITS.maxRecords)
    local limit = validateInteger(
        options.limit or Constants.LIMITS.maxQueryRows,
        0, Constants.LIMITS.maxQueryRows)
    if offset == nil or limit == nil then
        return nil, "invalidOptions"
    end
    local allCandidates = {}
    local openOffset = 0
    local totalOpen = 0
    local reason = nil
    repeat
        local listed
        listed, reason = self:listCycles({
            farmId = options.farmId,
            fieldGrouped = true,
            limit = Constants.LIMITS.maxQueryRows,
            newestFirst = true,
            offset = openOffset,
            state = Constants.CYCLE_STATE.Open
        })
        if listed == nil then
            return nil, reason
        end
        totalOpen = listed.page.total
        for _, cycle in ipairs(listed.cycles) do
            local evidence
            evidence, reason = self:getCycleBoundaryEvidence(cycle.id)
            if evidence == nil then
                return nil, reason
            end
            if evidence.hasHarvest then
                local reviewRevision
                reviewRevision, reason =
                    self:getCanonicalCycleRevision(cycle.id)
                if reviewRevision == nil then
                    return nil, reason
                end
                allCandidates[#allCandidates + 1] = {
                    cycle = cycle,
                    evidence = evidence,
                    reviewSnapshot = {
                        revision = reviewRevision,
                        lastHarvestRecordId =
                            evidence.lastHarvestRecordId,
                        lastHarvestMissionTime =
                            evidence.lastHarvestMissionTime,
                        lastActivityMissionTime =
                            evidence.lastActivityMissionTime
                    }
                }
            end
        end
        openOffset = listed.page.nextOffset
    until openOffset == nil
    local candidates = {}
    local last = math.min(#allCandidates, offset + limit)
    local previousLandKey = nil
    for index = offset + 1, last do
        local row = allCandidates[index]
        row.fieldGroupStart = previousLandKey ~= row.cycle.landKey
        previousLandKey = row.cycle.landKey
        candidates[#candidates + 1] = row
    end
    local nextOffset = nil
    if limit > 0 and offset + #candidates < #allCandidates then
        nextOffset = offset + #candidates
    end
    local fieldGroupContinuesFromPreviousPage = false
    if offset > 0 and #candidates > 0 then
        local previous = allCandidates[offset]
        local current = allCandidates[offset + 1]
        fieldGroupContinuesFromPreviousPage =
            previous ~= nil and current ~= nil
            and previous.cycle.landKey == current.cycle.landKey
        candidates[1].fieldGroupContinuesFromPreviousPage =
            fieldGroupContinuesFromPreviousPage
    end
    return {
        candidates = candidates,
        page = {
            offset = offset,
            limit = limit,
            total = #allCandidates,
            totalOpen = totalOpen,
            nextOffset = nextOffset,
            fieldGroupContinuesFromPreviousPage =
                fieldGroupContinuesFromPreviousPage
        }
    }
end

function Ledger:getOpenCycle(landKey)
    local landParts, landError = validateLandKey(landKey)
    if landParts == nil then
        return nil, landError
    end
    local cycleId = self.openCycleByLand[landKey]
    if cycleId == nil then
        return nil, "noOpenCycle"
    end
    local cycle = self.cyclesById[cycleId]
    if cycle == nil
        or cycle.state ~= Constants.CYCLE_STATE.Open
        or cycle.landKey ~= landKey
        or cycle.farmId ~= landParts.farmId
        or cycle.farmlandId ~= landParts.farmlandId
        or cycle.fieldId ~= landParts.fieldId
        or cycle.fieldKind ~= landParts.fieldKind then
        return nil, "cycleIndexCorrupt"
    end
    return self:_copyForCaller(cycle)
end

function Ledger:promoteCycleDescriptor(command)
    if type(command) ~= "table" or getmetatable(command) ~= nil then
        return nil, "invalidCommand"
    end
    local cycle = self.cyclesById[rawget(command, "cycleId")]
    if cycle == nil then return nil, "unknownCycle" end
    if cycle.state ~= Constants.CYCLE_STATE.Open then
        return nil, "openCycleRequired"
    end
    local fruitType, reason = validateToken(rawget(command, "fruitType"))
    if fruitType == nil then return nil, reason end
    if fruitType == "unknown" then return nil, "knownCropRequired" end
    local fruitTypeId = rawget(command, "fruitTypeId")
    if fruitTypeId ~= nil then
        fruitTypeId, reason = validateInteger(
            fruitTypeId, 0, Constants.LIMITS.maxIdentifier)
        if fruitTypeId == nil then return nil, reason end
    end
    local fillTypeId = rawget(command, "fillTypeId")
    if fillTypeId ~= nil then
        fillTypeId, reason = validateInteger(
            fillTypeId, 0, Constants.LIMITS.maxIdentifier)
        if fillTypeId == nil then return nil, reason end
    end
    if cycle.fruitType ~= "unknown" then
        if cycle.fruitType == fruitType
            and cycle.fruitTypeId == fruitTypeId
            and cycle.fillTypeId == fillTypeId then
            return self:_copyForCaller(cycle), false
        end
        return nil, "cycleDescriptorMismatch"
    end
    if cycle.fruitTypeId ~= nil and fruitTypeId ~= nil
        and cycle.fruitTypeId ~= fruitTypeId then
        return nil, "cycleDescriptorMismatch"
    end
    fruitTypeId = fruitTypeId or cycle.fruitTypeId
    local proposed = shallowCopy(cycle)
    proposed.fruitType = fruitType
    proposed.fruitTypeId = fruitTypeId
    proposed.fillTypeId = fillTypeId
    proposed.reasons = {}
    for _, value in ipairs(cycle.reasons) do
        if value ~= "cropUnknown" then
            proposed.reasons[#proposed.reasons + 1] = value
        end
    end
    if #proposed.reasons == 0
        and proposed.qualityClass == Constants.QUALITY_CLASS.Partial then
        proposed.qualityClass = Constants.QUALITY_CLASS.Complete
    end
    local budgetDelta, budgetError = self:_replacementNeutralDelta(cycle, proposed)
    if budgetDelta == nil then return nil, budgetError end
    local budgeted, budgetReason = self:_preflightNeutralDelta(budgetDelta)
    if not budgeted then
        return nil, budgetReason or "ledgerNeutralBudgetExceeded"
    end
    cycle.fruitType = proposed.fruitType
    cycle.fruitTypeId = proposed.fruitTypeId
    cycle.fillTypeId = proposed.fillTypeId
    cycle.reasons = proposed.reasons
    cycle.qualityClass = proposed.qualityClass
    self:_commitNeutralDelta(budgetDelta)
    self:_touchReport(cycle.id)
    return self:_copyForCaller(cycle), true
end

function Ledger:createObservationId(vehicleUniqueId, sequence, discriminator)
    local _, identifiers, dependencyError = dependencies()
    if dependencyError ~= nil then
        return nil, dependencyError
    end
    return identifiers.observationId(
        self.epoch,
        vehicleUniqueId,
        sequence,
        discriminator
    )
end

function Ledger:closeCycle(command)
    if type(command) ~= "table" then
        return nil, "invalidCommand"
    end
    local cycle = self.cyclesById[command.cycleId]
    if cycle == nil then
        return nil, "unknownCycle"
    end
    if cycle.state ~= Constants.CYCLE_STATE.Open then
        return nil, "invalidCycleTransition"
    end
    for _, sessionId in ipairs(self.sessionOrder) do
        local session = self.sessionsById[sessionId]
        if session.cycleId == cycle.id and session.state == Constants.SESSION_STATE.Open then
            return nil, "cycleHasOpenSession"
        end
    end
    local missionTime, timeError = validateMissionTime(command.missionTime)
    if missionTime == nil or missionTime < cycle.startMissionTime then
        return nil, timeError or "timeBeforeCycleStart"
    end
    local lastActivityTime = self.lastActivityTimeByCycle[cycle.id]
    if lastActivityTime ~= nil and missionTime < lastActivityTime then
        return nil, "timeBeforeCycleActivity"
    end
    local period, periodError = validateInteger(command.period, 1, Constants.LIMITS.maxPeriod)
    if period == nil then
        return nil, periodError
    end
    local reason, reasonError = validateToken(command.reason or "manualClose")
    if reason == nil then
        return nil, reasonError
    end
    local year = nil
    if command.year ~= nil then
        if self.settings.calendarYearSupported ~= true then
            return nil, "calendarYearUnsupported"
        end
        local yearError = nil
        year, yearError = validateInteger(command.year, 0, Constants.LIMITS.maxYear)
        if year == nil then
            return nil, yearError
        end
        if cycle.startYear ~= nil
            and (year < cycle.startYear
                or (year == cycle.startYear and period < cycle.startPeriod)) then
            return nil, "calendarBeforeCycleStart"
        end
    end
    local proposed = shallowCopy(cycle)
    proposed.state = Constants.CYCLE_STATE.Closed
    proposed.endMissionTime = missionTime
    proposed.endPeriod = period
    proposed.closeReason = reason
    proposed.endYear = year
    local budgetDelta, budgetError = self:_replacementNeutralDelta(cycle, proposed)
    if budgetDelta == nil then
        return nil, budgetError
    end
    local budgeted = self:_preflightNeutralDelta(budgetDelta)
    if not budgeted then
        return nil, "ledgerNeutralBudgetExceeded"
    end
    cycle.state = proposed.state
    cycle.endMissionTime = proposed.endMissionTime
    cycle.endPeriod = proposed.endPeriod
    cycle.closeReason = proposed.closeReason
    cycle.endYear = proposed.endYear
    self:_commitNeutralDelta(budgetDelta)
    if self.openCycleByLand[cycle.landKey] == cycle.id then
        self.openCycleByLand[cycle.landKey] = nil
    end
    clearCycleSegmentReplay(self, cycle.id)
    self:_touchReport(cycle.id)
    return self:_copyForCaller(cycle)
end

function Ledger:closeCycles(command)
    if type(command) ~= "table" or getmetatable(command) ~= nil then
        return nil, "invalidCommand"
    end
    local acceptedIds, arrayError = Core.Validation.array(
        rawget(command, "cycleIds"), Constants.LIMITS.maxQueryRows)
    if acceptedIds == nil or #acceptedIds == 0 then
        return nil, arrayError or "invalidCycleSelection"
    end
    local missionTime, timeError =
        validateMissionTime(rawget(command, "missionTime"))
    if missionTime == nil then
        return nil, timeError
    end
    local period, periodError = validateInteger(
        rawget(command, "period"), 1, Constants.LIMITS.maxPeriod)
    if period == nil then
        return nil, periodError
    end
    local reason, reasonError = validateToken(rawget(command, "reason"))
    if reason == nil then
        return nil, reasonError
    end
    local checkpointSessions = rawget(command, "checkpointSessions")
    if checkpointSessions == nil then
        checkpointSessions = false
    elseif type(checkpointSessions) ~= "boolean" then
        return nil, "invalidCommand"
    end
    local year = rawget(command, "year")
    if year ~= nil then
        year, timeError = validateInteger(
            year, 0, Constants.LIMITS.maxYear)
        if year == nil then
            return nil, timeError
        end
    end
    local selected = {}
    local proposedRows = {}
    local proposedSessionRows = {}
    local totalDelta = 0
    for _, cycleId in ipairs(acceptedIds) do
        if type(cycleId) ~= "string" or selected[cycleId] then
            return nil, "invalidCycleSelection"
        end
        selected[cycleId] = true
        local cycle = self.cyclesById[cycleId]
        if cycle == nil then
            return nil, "unknownCycle"
        end
        if cycle.state ~= Constants.CYCLE_STATE.Open then
            return nil, "invalidCycleTransition"
        end
        for _, sessionId in ipairs(self.sessionOrder) do
            local session = self.sessionsById[sessionId]
            if session.cycleId == cycle.id
                    and session.state == Constants.SESSION_STATE.Open then
                if not checkpointSessions then
                    return nil, "cycleHasOpenSession"
                end
                if missionTime < session.lastEvidenceTime then
                    return nil, "timeBeforeLastEvidence"
                end
                local proposedSession = shallowCopy(session)
                proposedSession.state = Constants.SESSION_STATE.Closed
                -- Match closeSession and the canonical reload contract: a
                -- session ends at its last accepted evidence, while the cycle
                -- itself may close later at the detected field boundary.
                proposedSession.endMissionTime = session.lastEvidenceTime
                proposedSession.closeReason = reason
                local sessionDelta, sessionDeltaError =
                    self:_replacementNeutralDelta(session, proposedSession)
                if sessionDelta == nil then
                    return nil, sessionDeltaError
                end
                totalDelta = totalDelta + sessionDelta
                proposedSessionRows[#proposedSessionRows + 1] = {
                    session = session,
                    proposed = proposedSession
                }
            end
        end
        if missionTime < cycle.startMissionTime then
            return nil, "timeBeforeCycleStart"
        end
        local lastActivityTime = self.lastActivityTimeByCycle[cycle.id]
        if lastActivityTime ~= nil and missionTime < lastActivityTime then
            return nil, "timeBeforeCycleActivity"
        end
        local cycleYear = nil
        if self.settings.calendarYearSupported then
            cycleYear = year or cycle.startYear
            if cycleYear < cycle.startYear
                or (cycleYear == cycle.startYear
                    and period < cycle.startPeriod) then
                return nil, "calendarBeforeCycleStart"
            end
        end
        local proposed = shallowCopy(cycle)
        proposed.state = Constants.CYCLE_STATE.Closed
        proposed.endMissionTime = missionTime
        proposed.endPeriod = period
        proposed.closeReason = reason
        proposed.endYear = cycleYear
        local delta, deltaError =
            self:_replacementNeutralDelta(cycle, proposed)
        if delta == nil then
            return nil, deltaError
        end
        totalDelta = totalDelta + delta
        proposedRows[#proposedRows + 1] = {
            cycle=cycle, proposed=proposed
        }
    end
    local budgeted, budgetReason = self:_preflightNeutralDelta(totalDelta)
    if not budgeted then
        return nil, budgetReason
    end
    local closedSessions = {}
    for _, row in ipairs(proposedSessionRows) do
        local session, proposed = row.session, row.proposed
        session.state = proposed.state
        session.endMissionTime = proposed.endMissionTime
        session.closeReason = proposed.closeReason
        local contextKey = self.contextKeyBySession[session.id]
        if contextKey ~= nil
                and self.openSessionByContext[contextKey] == session.id then
            self.openSessionByContext[contextKey] = nil
        end
        local rootVehicleId =
            self.rootKeyBySession[session.id] or session.rootVehicleId
        if rootVehicleId ~= nil
                and self.openSessionByRoot[rootVehicleId] == session.id then
            self.openSessionByRoot[rootVehicleId] = nil
        end
        self.contextKeyBySession[session.id] = nil
        self.rootKeyBySession[session.id] = nil
        self.lastEvidenceSequenceBySession[session.id] = nil
        self.lastEvidencePayloadBySession[session.id] = nil
clearSegmentState(self, session.id)
        closedSessions[#closedSessions + 1] = session.id
    end
    local closed = {}
    for _, row in ipairs(proposedRows) do
        local cycle = row.cycle
        local proposed = row.proposed
        cycle.state = proposed.state
        cycle.endMissionTime = proposed.endMissionTime
        cycle.endPeriod = proposed.endPeriod
        cycle.closeReason = proposed.closeReason
        cycle.endYear = proposed.endYear
        if self.openCycleByLand[cycle.landKey] == cycle.id then
            self.openCycleByLand[cycle.landKey] = nil
        end
        clearCycleSegmentReplay(self, cycle.id)
        self:_touchReport(cycle.id)
        closed[#closed + 1] = self:_copyForCaller(cycle)
    end
    self:_commitNeutralDelta(totalDelta)
    return closed, closedSessions
end

function Ledger:archiveCycle(cycleId, transitionReason, retentionSummary)
    return nil, "retentionTransactionRequired"
end

function Ledger:_retentionPlanPreservesQuery(plan)
    if type(plan) ~= "table" or getmetatable(plan) ~= nil then
        return nil, "invalidRetentionPlan"
    end
    local cycleId = plan.cycleId
    if self.cyclesById[cycleId] == nil then
        return nil, "unknownCycle"
    end
    local beforeQuery, queryError = self:queryCycle(cycleId, {
        recordLimit = 0
    })
    if beforeQuery == nil then
        return nil, queryError
    end
    local afterQuery = nil
    afterQuery, queryError = self:queryCycle(cycleId, {
        _retentionPlan = plan,
        recordLimit = 0
    })
    if afterQuery == nil then
        return nil, queryError
    end
    if not neutralEqual(beforeQuery.categoryTotals, afterQuery.categoryTotals)
        or not neutralEqual(beforeQuery.qualityCounts, afterQuery.qualityCounts)
        or beforeQuery.directReplacementOverlap ~= afterQuery.directReplacementOverlap then
        return nil, "retentionWouldChangeTotals"
    end
    return true
end

function Ledger:validateRetentionSummary(retentionSummary)
    local normalized, summaryError = normalizeRetentionSummary(retentionSummary)
    if normalized == nil then
        return nil, summaryError
    end
    return self:_copyForCaller(normalized)
end

function Ledger:_setRetentionSettings(mode, keepYears)
    local proposed = shallowCopy(self.settings)
    proposed.retentionMode = mode
    proposed.retentionYears = keepYears
    local budgetDelta, budgetError = self:_replacementNeutralDelta(self.settings, proposed)
    if budgetDelta == nil then
        return nil, budgetError
    end
    local budgeted, budgetReason = self:_preflightNeutralDelta(budgetDelta)
    if not budgeted then
        return nil, budgetReason
    end
    self.settings.retentionMode = mode
    self.settings.retentionYears = keepYears
    self:_commitNeutralDelta(budgetDelta)
    return self:_copyForCaller(self.settings)
end

local function validateSelectionSet(value)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        return nil, "invalidRetentionSelection"
    end
    for key, selected in pairs(value) do
        if type(key) ~= "string" or selected ~= true then
            return nil, "invalidRetentionSelection"
        end
    end
    return value
end

function Ledger:_retentionPlanNeutralDelta(plan)
    if type(plan) ~= "table" or getmetatable(plan) ~= nil then
        return nil, "invalidRetentionPlan"
    end
    local cycleId = rawget(plan, "cycleId")
    local cycle = self.cyclesById[cycleId]
    if cycle == nil then
        return nil, "unknownCycle"
    end
    if cycle.state ~= Constants.CYCLE_STATE.Closed or cycle.retentionSummary ~= nil then
        return nil, "invalidCycleTransition"
    end
    local recordsToPrune, selectionError = validateSelectionSet(
        rawget(plan, "recordsToPrune")
    )
    if recordsToPrune == nil then
        return nil, selectionError
    end
    local sessionsToPrune = nil
    sessionsToPrune, selectionError = validateSelectionSet(
        rawget(plan, "sessionsToPrune")
    )
    if sessionsToPrune == nil then
        return nil, selectionError
    end
    local summary, summaryError = normalizeRetentionSummary(
        rawget(plan, "summary")
    )
    if summary == nil then
        return nil, summaryError
    end
    local protectedRecords, protectedSessions, protectionError = retentionProtection(
        self,
        cycle
    )
    if protectedRecords == nil then
        return nil, protectionError
    end

    local removedItems = 0
    local selectedRecordCount = 0
    for _, recordId in ipairs(self.recordOrder) do
        local record = self.recordsById[recordId]
        if record.cycleId == cycleId then
            local expectedSelected = not protectedRecords[recordId]
            if (recordsToPrune[recordId] == true) ~= expectedSelected then
                return nil, "retentionSelectionMismatch"
            end
            if expectedSelected then
                local recordItems, countError = neutralItemCount(record)
                if recordItems == nil then
                    return nil, countError
                end
                selectedRecordCount = selectedRecordCount + 1
                removedItems = removedItems + recordItems
            end
        elseif recordsToPrune[recordId] then
            return nil, "retentionSelectionMismatch"
        end
    end
    for recordId in pairs(recordsToPrune) do
        local record = self.recordsById[recordId]
        if record == nil or record.cycleId ~= cycleId then
            return nil, "retentionSelectionMismatch"
        end
    end

    local selectedSessionCount = 0
    for _, sessionId in ipairs(self.sessionOrder) do
        local session = self.sessionsById[sessionId]
        if session.cycleId == cycleId then
            local expectedSelected = not protectedSessions[sessionId]
            if (sessionsToPrune[sessionId] == true) ~= expectedSelected then
                return nil, "retentionSelectionMismatch"
            end
            if expectedSelected then
                if session.state ~= Constants.SESSION_STATE.Closed then
                    return nil, "openSessionRetentionForbidden"
                end
                local sessionItems, countError = neutralItemCount(session)
                if sessionItems == nil then
                    return nil, countError
                end
                selectedSessionCount = selectedSessionCount + 1
                removedItems = removedItems + sessionItems
            end
        elseif sessionsToPrune[sessionId] then
            return nil, "retentionSelectionMismatch"
        end
    end
    for sessionId in pairs(sessionsToPrune) do
        local session = self.sessionsById[sessionId]
        if session == nil or session.cycleId ~= cycleId then
            return nil, "retentionSelectionMismatch"
        end
    end

    local proposedCycle = shallowCopy(cycle)
    proposedCycle.state = Constants.CYCLE_STATE.Archived
    proposedCycle.archiveReason = "retentionCompaction"
    proposedCycle.retentionSummary = summary
    local cycleDelta, countError = self:_replacementNeutralDelta(
        cycle,
        proposedCycle
    )
    if cycleDelta == nil then
        return nil, countError
    end
    return cycleDelta - removedItems, selectedRecordCount, selectedSessionCount
end

function Ledger:_validateArchivedResidual(cycle)
    local protectedRecords, protectedSessions, protectionError = retentionProtection(self, cycle)
    if protectedRecords == nil then
        return nil, protectionError
    end
    for _, recordId in ipairs(self.recordOrder) do
        local record = self.recordsById[recordId]
        if record.cycleId == cycle.id and not protectedRecords[recordId] then
            return nil, "impossibleArchivedResidual"
        end
    end
    for _, sessionId in ipairs(self.sessionOrder) do
        local session = self.sessionsById[sessionId]
        if session.cycleId == cycle.id and not protectedSessions[sessionId] then
            return nil, "impossibleArchivedResidual"
        end
    end
    return true
end

function Ledger:_applyRetentionPlan(plan)
    if type(plan) ~= "table" or getmetatable(plan) ~= nil then
        return nil, "invalidRetentionPlan"
    end
    local cycle = self.cyclesById[plan.cycleId]
    if cycle == nil then
        return nil, "unknownCycle"
    end
    if cycle.state ~= Constants.CYCLE_STATE.Closed or cycle.retentionSummary ~= nil then
        return nil, "invalidCycleTransition"
    end
    local recordsToPrune, selectionError = validateSelectionSet(plan.recordsToPrune)
    if recordsToPrune == nil then
        return nil, selectionError
    end
    local sessionsToPrune = nil
    sessionsToPrune, selectionError = validateSelectionSet(plan.sessionsToPrune)
    if sessionsToPrune == nil then
        return nil, selectionError
    end
    local summary, summaryError = normalizeRetentionSummary(plan.summary)
    if summary == nil then
        return nil, summaryError
    end
    local budgetDelta, plannedRecordCount, plannedSessionCount =
        self:_retentionPlanNeutralDelta(plan)
    if budgetDelta == nil then
        return nil, plannedRecordCount
    end
    local protectedRecords, protectedSessions, protectionError = retentionProtection(self, cycle)
    if protectedRecords == nil then
        return nil, protectionError
    end
    local exactSum, exactError = exactSumDependency()
    if exactSum == nil then
        return nil, exactError
    end

    local groups = {}
    local selectedRecordCount = 0
    for _, recordId in ipairs(self.recordOrder) do
        local record = self.recordsById[recordId]
        if record.cycleId == cycle.id then
            local expectedSelected = not protectedRecords[recordId]
            if (recordsToPrune[recordId] == true) ~= expectedSelected then
                return nil, "retentionSelectionMismatch"
            end
            if expectedSelected then
                selectedRecordCount = selectedRecordCount + 1
                local key = retentionEntryKey(record)
                local group = groups[key]
                if group == nil then
                    local accumulator = nil
                    local maximum = nil
                    if record.amount ~= nil then
                        maximum = amountLimitForUnit(record.unit)
                        if maximum == nil then
                            return nil, "retentionAggregateOutOfRange"
                        end
                        accumulator, exactError = exactSum.new(
                            maximum,
                            Constants.LIMITS.maxRecords
                        )
                        if accumulator == nil then
                            return nil, exactError
                        end
                    end
                    group = {
                        recordType = record.recordType,
                        accountingClass = record.accountingClass,
                        qualityClass = record.qualityClass,
                        category = record.category,
                        _exactSum = accumulator,
                        _maximum = maximum,
                        unit = record.unit,
                        direction = record.direction,
                        sourceRecordCount = 0,
                        reasons = record.reasons
                    }
                    groups[key] = group
                end
                if record.amount ~= nil then
                    local added, addError = exactSum.add(group._exactSum, record.amount)
                    if not added then
                        return nil, addError
                    end
                end
                group.sourceRecordCount = group.sourceRecordCount + 1
            end
        elseif recordsToPrune[recordId] then
            return nil, "retentionSelectionMismatch"
        end
    end
    for recordId in pairs(recordsToPrune) do
        local record = self.recordsById[recordId]
        if record == nil or record.cycleId ~= cycle.id then
            return nil, "retentionSelectionMismatch"
        end
    end

    local selectedSessionCount = 0
    for _, sessionId in ipairs(self.sessionOrder) do
        local session = self.sessionsById[sessionId]
        if session.cycleId == cycle.id then
            local expectedSelected = not protectedSessions[sessionId]
            if (sessionsToPrune[sessionId] == true) ~= expectedSelected then
                return nil, "retentionSelectionMismatch"
            end
            if expectedSelected then
                if session.state ~= Constants.SESSION_STATE.Closed then
                    return nil, "openSessionRetentionForbidden"
                end
                selectedSessionCount = selectedSessionCount + 1
            end
        elseif sessionsToPrune[sessionId] then
            return nil, "retentionSelectionMismatch"
        end
    end
    for sessionId in pairs(sessionsToPrune) do
        local session = self.sessionsById[sessionId]
        if session == nil or session.cycleId ~= cycle.id then
            return nil, "retentionSelectionMismatch"
        end
    end

    local keys = {}
    for key in pairs(groups) do
        keys[#keys + 1] = key
    end
    table.sort(keys, byteLess)
    local entries = {}
    for index, key in ipairs(keys) do
        local group = groups[key]
        if group._exactSum ~= nil then
            local _, finishError = exactSum.finish(group._exactSum, group._maximum)
            if finishError ~= nil then
                if finishError == "aggregateOutOfRange" then
                    return nil, "retentionAggregateOutOfRange"
                end
                return nil, finishError
            end
            group.exactSum, exactError = exactSum.toNeutral(group._exactSum)
            if group.exactSum == nil then
                return nil, exactError
            end
        end
        group._exactSum = nil
        group._maximum = nil
        entries[index] = group
    end
    local beforeQuery, queryError = self:queryCycle(cycle.id, {
        recordLimit = 0
    })
    if beforeQuery == nil then
        return nil, queryError
    end
    local expectedSummary = {
        compactedAtYear = summary.compactedAtYear,
        directReplacementOverlap = beforeQuery.directReplacementOverlap,
        entries = entries,
        prunedRecordCount = selectedRecordCount,
        prunedSessionCount = selectedSessionCount
    }
    local normalizedExpected = nil
    normalizedExpected, summaryError = normalizeRetentionSummary(expectedSummary)
    if normalizedExpected == nil then
        return nil, summaryError
    end
    if not neutralEqual(normalizedExpected, summary) then
        return nil, "retentionSummaryMismatch"
    end
    local preservesQuery, preservationError = self:_retentionPlanPreservesQuery(plan)
    if not preservesQuery then
        return nil, preservationError
    end
    if selectedRecordCount ~= plannedRecordCount
        or selectedSessionCount ~= plannedSessionCount then
        return nil, "retentionSelectionMismatch"
    end

    local proposedCycle = shallowCopy(cycle)
    proposedCycle.state = Constants.CYCLE_STATE.Archived
    proposedCycle.archiveReason = "retentionCompaction"
    proposedCycle.retentionSummary = summary
    local budgeted, budgetReason = self:_preflightNeutralDelta(budgetDelta)
    if not budgeted then
        return nil, budgetReason
    end

    for index = #self.recordOrder, 1, -1 do
        local recordId = self.recordOrder[index]
        if recordsToPrune[recordId] then
            local record = self.recordsById[recordId]
            self.observationIndex[record.observationId] = nil
            clearSegmentObservationOwnership(self, recordId)
            local transactionKey = directTransactionKey(record.directProvenance)
            if transactionKey ~= nil then
                self.directTransactionIndex[transactionKey] = nil
            end
            self.correctionsByTarget[recordId] = nil
            self.recordsById[recordId] = nil
            table.remove(self.recordOrder, index)
        end
    end
    for index = #self.sessionOrder, 1, -1 do
        local sessionId = self.sessionOrder[index]
        if sessionsToPrune[sessionId] then
            local session = self.sessionsById[sessionId]
            local contextKey = self.contextKeyBySession[sessionId]
            if contextKey ~= nil and self.openSessionByContext[contextKey] == sessionId then
                self.openSessionByContext[contextKey] = nil
            end
            local rootVehicleId = self.rootKeyBySession[sessionId] or session.rootVehicleId
            if rootVehicleId ~= nil and self.openSessionByRoot[rootVehicleId] == sessionId then
                self.openSessionByRoot[rootVehicleId] = nil
            end
            self.contextKeyBySession[sessionId] = nil
            self.rootKeyBySession[sessionId] = nil
            self.lastEvidenceSequenceBySession[sessionId] = nil
            self.lastEvidencePayloadBySession[sessionId] = nil
            self.sessionsById[sessionId] = nil
            table.remove(self.sessionOrder, index)
        end
    end
    cycle.state = proposedCycle.state
    cycle.archiveReason = proposedCycle.archiveReason
    cycle.retentionSummary = summary
    self:_commitNeutralDelta(budgetDelta)
    local rebuilt, rebuildReason = self:_rebuildCycleQueryIndexes(cycle.id)
    if not rebuilt then return nil, rebuildReason end
    local states, stateReason = buildCategoryStates(self, cycle.id)
    if states == nil then return nil, stateReason end
    self.categoryStatesByCycle[cycle.id] = states
    self:_touchReport(cycle.id)
    return {
        cycleId = cycle.id,
        prunedRecordCount = selectedRecordCount,
        prunedSessionCount = selectedSessionCount
    }
end

local function sessionContextKey(command)
    return lengthPrefixed({
        command.cycleId,
        command.landKey,
        command.rootVehicleId,
        command.operationType,
        command.fillType or "",
        command.operatorKind,
        command.operatorId or "",
        command.carrierKind or ""
    })
end

function Ledger:startSession(command)
    if type(command) ~= "table" or command.evidence ~= true then
        return nil, "positiveEvidenceRequired"
    end
    local cycle = self.cyclesById[command.cycleId]
    if cycle == nil or cycle.state ~= Constants.CYCLE_STATE.Open then
        return nil, "openCycleRequired"
    end
    if command.landKey ~= cycle.landKey then
        return nil, "landCycleMismatch"
    end
    local rootVehicleId, rootError = validateToken(command.rootVehicleId, Constants.LIMITS.idBytes)
    if rootVehicleId == nil then
        return nil, rootError
    end
    local operationType, operationError = validateToken(command.operationType)
    if operationType == nil or not Constants.OPERATION[operationType] then
        return nil, operationError or "unsupportedOperation"
    end
    local carrierKind, carrierError = validateOptionalToken(
        rawget(command, "carrierKind"))
    if carrierError ~= nil then return nil, carrierError end
    if carrierKind ~= nil
        and carrierKind ~= ZERO_CHANGED_APPLICATION_CARRIER_KIND then
        return nil, "unsupportedCarrierKind"
    end
    local missionTime, timeError = validateMissionTime(command.missionTime)
    if missionTime == nil then
        return nil, timeError
    end
    if missionTime < cycle.startMissionTime then
        return nil, "timeBeforeCycleStart"
    end
    local fillType, fillError = validateOptionalToken(command.fillType)
    if fillError ~= nil then
        return nil, fillError
    end
    local operatorKind, operatorError = validateToken(command.operatorKind or "unknown")
    if operatorKind == nil then
        return nil, operatorError
    end
    local operatorId, operatorIdError = validateOptionalToken(command.operatorId, Constants.LIMITS.idBytes)
    if operatorIdError ~= nil then
        return nil, operatorIdError
    end
    local operatorQuality = command.operatorQuality or Constants.QUALITY_CLASS.Partial
    if not Constants.QUALITY_CLASS_SET[operatorQuality] then
        return nil, "invalidOperatorQuality"
    end
    local reasons, reasonsError = normalizeReasons(command.reasons)
    if reasons == nil then
        return nil, reasonsError
    end
    if operatorQuality ~= Constants.QUALITY_CLASS.Complete and #reasons == 0 then
        reasons[1] = "operatorUnavailable"
    end
    if carrierKind ~= nil then
        local supportedOperation = false
        for _, expectedOperation in pairs(
            ZERO_CHANGED_APPLICATION_OPERATIONS) do
            if operationType == expectedOperation then
                supportedOperation = true
                break
            end
        end
        if not supportedOperation
            or not reasonsContain(reasons, "zeroChangedArea") then
            return nil, "invalidZeroChangedApplicationCarrier"
        end
    end
    local implements, implementsError = Core.Validation.array(command.implementIds or {}, Constants.LIMITS.maxReferences)
    if implements == nil then
        return nil, implementsError
    end
    local uniqueImplements = {}
    local implementSeen = {}
    for _, implementId in ipairs(implements) do
        local normalized, implementError = validateToken(implementId, Constants.LIMITS.idBytes)
        if normalized == nil then
            return nil, implementError
        end
        if not implementSeen[normalized] then
            implementSeen[normalized] = true
            uniqueImplements[#uniqueImplements + 1] = normalized
        end
    end
    table.sort(uniqueImplements, byteLess)
    local normalizedContext = {
        cycleId = cycle.id,
        landKey = cycle.landKey,
        rootVehicleId = rootVehicleId,
        operationType = operationType,
        fillType = fillType,
        operatorKind = operatorKind,
        operatorId = operatorId,
        carrierKind = carrierKind
    }
    local contextKey = sessionContextKey(normalizedContext)
    local function buildNewSession(id)
        return {
            id = id,
            cycleId = cycle.id,
            landKey = cycle.landKey,
            rootVehicleId = rootVehicleId,
            operationType = operationType,
            fillType = fillType,
            operatorKind = operatorKind,
            operatorId = operatorId,
            carrierKind = carrierKind,
            operatorQuality = operatorQuality,
            implementIds = uniqueImplements,
            state = Constants.SESSION_STATE.Open,
            firstEvidenceTime = missionTime,
            lastEvidenceTime = missionTime,
            activeMs = 0,
            reasons = reasons
        }
    end
    local contextId = self.openSessionByContext[contextKey]
    if contextId ~= nil then
        local contextSession = self.sessionsById[contextId]
        if contextSession == nil or contextSession.state ~= Constants.SESSION_STATE.Open then
            self.openSessionByContext[contextKey] = nil
            contextId = nil
        end
    end
    local rootId = self.openSessionByRoot[rootVehicleId]
    if rootId ~= nil then
        local rootSession = self.sessionsById[rootId]
        if rootSession == nil or rootSession.state ~= Constants.SESSION_STATE.Open then
            self.openSessionByRoot[rootVehicleId] = nil
            rootId = nil
        end
    end
    if contextId ~= nil and rootId ~= nil and contextId ~= rootId then
        return nil, "sessionIndexCorrupt"
    end
    local existingId = rootId or contextId
    local existing = existingId and self.sessionsById[existingId] or nil
    if existing ~= nil then
        if missionTime < existing.lastEvidenceTime then
            return nil, "outOfOrderEvidence"
        end
        local sameContext = self.contextKeyBySession[existing.id] == contextKey
        if sameContext and missionTime - existing.lastEvidenceTime < Constants.STOP_GRACE_MS then
            local merged = {}
            local mergedImplements = {}
            for _, implementId in ipairs(existing.implementIds) do
                merged[implementId] = true
                mergedImplements[#mergedImplements + 1] = implementId
            end
            for _, implementId in ipairs(uniqueImplements) do
                if not merged[implementId] then
                    if #mergedImplements >= Constants.LIMITS.maxReferences then
                        return nil, "tooManyImplements"
                    end
                    merged[implementId] = true
                    mergedImplements[#mergedImplements + 1] = implementId
                end
            end
            local mergedReasons, mergeError = mergeReasons(existing.reasons, reasons)
            if mergedReasons == nil then
                return nil, mergeError
            end
            table.sort(mergedImplements, byteLess)
            local proposed = shallowCopy(existing)
            proposed.implementIds = mergedImplements
            proposed.operatorQuality = lowerQuality(existing.operatorQuality, operatorQuality)
            proposed.reasons = mergedReasons
            proposed.lastEvidenceTime = missionTime
            local budgetDelta, budgetError = self:_replacementNeutralDelta(existing, proposed)
            if budgetDelta == nil then
                return nil, budgetError
            end
            local budgeted, budgetReason = self:_preflightNeutralDelta(budgetDelta)
            if not budgeted then
                return nil, budgetReason
            end
            existing.implementIds = mergedImplements
            existing.operatorQuality = proposed.operatorQuality
            existing.reasons = mergedReasons
            existing.lastEvidenceTime = missionTime
            self:_commitNeutralDelta(budgetDelta)
            self.openSessionByContext[contextKey] = existing.id
            self.openSessionByRoot[rootVehicleId] = existing.id
            self.rootKeyBySession[existing.id] = rootVehicleId
            self.lastActivityTimeByCycle[cycle.id] = math.max(
                self.lastActivityTimeByCycle[cycle.id] or missionTime,
                missionTime
            )
            return self:_copyForCaller(existing), false
        else
            local previewId, previewError = self:_previewId("session")
            if previewId == nil then
                return nil, previewError
            end
            local candidate = buildNewSession(previewId)
            local candidateItems, countError = neutralItemCount(candidate)
            if candidateItems == nil then
                return nil, countError
            end
            local proposedClosed = shallowCopy(existing)
            proposedClosed.state = Constants.SESSION_STATE.Closed
            proposedClosed.endMissionTime = existing.lastEvidenceTime
            proposedClosed.closeReason = sameContext and "evidenceTimeout" or "contextChanged"
            local closeDelta = nil
            closeDelta, countError = self:_replacementNeutralDelta(existing, proposedClosed)
            if closeDelta == nil then
                return nil, countError
            end
            local budgeted, budgetReason = self:_preflightNeutralDelta(
                closeDelta + candidateItems
            )
            if not budgeted then
                return nil, budgetReason
            end
            local closed, closeError = self:closeSession({
                sessionId = existing.id,
                reason = proposedClosed.closeReason,
                endMissionTime = missionTime
            })
            if closed == nil then
                return nil, closeError
            end
        end
    end
    local previewId, previewError = self:_previewId("session")
    if previewId == nil then
        return nil, previewError
    end
    local session = buildNewSession(previewId)
    local sessionItems, countError = neutralItemCount(session)
    if sessionItems == nil then
        return nil, countError
    end
    local budgeted, budgetReason = self:_preflightNeutralDelta(sessionItems)
    if not budgeted then
        return nil, budgetReason
    end
    local id, idError = self:_allocateId("session")
    if id == nil then
        return nil, idError
    end
    if id ~= previewId then
        return nil, "identifierAllocationChanged"
    end
    self.sessionsById[id] = session
    self.sessionOrder[#self.sessionOrder + 1] = id
    self.openSessionByContext[contextKey] = id
    self.openSessionByRoot[rootVehicleId] = id
    self.contextKeyBySession[id] = contextKey
    self.rootKeyBySession[id] = rootVehicleId
    self.lastActivityTimeByCycle[cycle.id] = math.max(
        self.lastActivityTimeByCycle[cycle.id] or missionTime,
        missionTime
    )
    self:_commitNeutralDelta(sessionItems)
    return self:_copyForCaller(session), true
end

-- Persisted carrier sessions retain only their first and last callback times.
-- A valid live chain can therefore span more than STOP_GRACE_MS overall even
-- though every adjacent callback remained inside the grace window.  Loading
-- must restore that already-validated timing without inventing intermediate
-- callbacks, charging evidence, or allocating a replacement session.
local function replayCarrierTiming(ledger, sessionId, missionTime)
    if ledger._loadingNeutral ~= true then
        return nil, "carrierReplayForbidden"
    end
    local session = ledger.sessionsById[sessionId]
    if session == nil or session.state ~= Constants.SESSION_STATE.Open then
        return nil, "openSessionRequired"
    end
    if session.carrierKind ~= ZERO_CHANGED_APPLICATION_CARRIER_KIND
        or session.activeMs ~= 0 then
        return nil, "invalidZeroChangedApplicationCarrier"
    end
    local restoredTime, timeError = validateMissionTime(missionTime)
    if restoredTime == nil then return nil, timeError end
    if restoredTime < session.lastEvidenceTime then
        return nil, "outOfOrderEvidence"
    end
    if restoredTime == session.lastEvidenceTime then
        return ledger:_copyForCaller(session), false
    end
    local contextKey = ledger.contextKeyBySession[session.id]
    local rootVehicleId = ledger.rootKeyBySession[session.id]
    if contextKey == nil or rootVehicleId ~= session.rootVehicleId
        or ledger.openSessionByContext[contextKey] ~= session.id
        or ledger.openSessionByRoot[rootVehicleId] ~= session.id then
        return nil, "sessionIndexCorrupt"
    end
    local proposed = shallowCopy(session)
    proposed.lastEvidenceTime = restoredTime
    local budgetDelta, budgetError =
        ledger:_replacementNeutralDelta(session, proposed)
    if budgetDelta == nil then return nil, budgetError end
    local budgeted, budgetReason = ledger:_preflightNeutralDelta(budgetDelta)
    if not budgeted then return nil, budgetReason end
    session.lastEvidenceTime = restoredTime
    ledger.lastActivityTimeByCycle[session.cycleId] = math.max(
        ledger.lastActivityTimeByCycle[session.cycleId] or restoredTime,
        restoredTime)
    ledger:_commitNeutralDelta(budgetDelta)
    return ledger:_copyForCaller(session), true
end

function Ledger:recordEvidence(command)
    if type(command) ~= "table" then
        return nil, "invalidCommand"
    end
    local session = self.sessionsById[command.sessionId]
    if session == nil or session.state ~= Constants.SESSION_STATE.Open then
        return nil, "openSessionRequired"
    end
    if session.carrierKind ~= nil then
        return nil, "carrierEvidenceForbidden"
    end
    local sequence, sequenceError = validateInteger(command.serverSequence, 0, Constants.LIMITS.maxIdentifier)
    if sequence == nil then
        return nil, sequenceError
    end
    local activeMs, activeError = validateNumber(command.activeMs, 0, Constants.LIMITS.maxDurationMs)
    if activeMs == nil then
        return nil, activeError
    end
    local missionTime, timeError = validateMissionTime(command.missionTime)
    if missionTime == nil then
        return nil, timeError
    end
    local rootVehicleId = session.rootVehicleId
    local lastSequence = self.lastEvidenceSequenceByRoot[rootVehicleId]
    if lastSequence ~= nil and sequence == lastSequence then
        local previous = self.lastEvidencePayloadByRoot[rootVehicleId]
        if previous ~= nil
            and previous.sessionId == session.id
            and previous.activeMs == activeMs
            and previous.missionTime == missionTime then
            return self:_copyForCaller(session), false
        end
        return nil, "evidenceSequenceCollision"
    end
    if lastSequence ~= nil and sequence < lastSequence then
        return nil, "outOfOrderSequence"
    end
    if missionTime < session.lastEvidenceTime then
        return nil, timeError or "outOfOrderEvidence"
    end
    if session.activeMs + activeMs > Constants.LIMITS.maxDurationMs then
        return nil, "durationOutOfRange"
    end
    if self._loadingNeutral ~= true then
        self.lastEvidenceSequenceByRoot[rootVehicleId] = sequence
        self.lastEvidencePayloadByRoot[rootVehicleId] = {
            sessionId = session.id,
            activeMs = activeMs,
            missionTime = missionTime
        }
    end
    self.lastEvidenceSequenceBySession[session.id] = sequence
    self.lastEvidencePayloadBySession[session.id] = {
        activeMs = activeMs,
        missionTime = missionTime
    }
    session.activeMs = session.activeMs + activeMs
    session.lastEvidenceTime = missionTime
    self.lastActivityTimeByCycle[session.cycleId] = math.max(
        self.lastActivityTimeByCycle[session.cycleId] or missionTime,
        missionTime
    )
    return self:_copyForCaller(session), true
end

function Ledger:closeSession(command)
    if type(command) ~= "table" then
        return nil, "invalidCommand"
    end
    local session = self.sessionsById[command.sessionId]
    if session == nil then
        return nil, "unknownSession"
    end
    if session.state == Constants.SESSION_STATE.Closed then
        return self:_copyForCaller(session), false
    end
    local reason, reasonError = validateToken(command.reason or "explicitClose")
    if reason == nil then
        return nil, reasonError
    end
    local endTime = session.lastEvidenceTime
    if command.endMissionTime ~= nil then
        local supplied, timeError = validateMissionTime(command.endMissionTime)
        if supplied == nil then
            return nil, timeError
        end
        if supplied < session.lastEvidenceTime then
            return nil, "timeBeforeLastEvidence"
        end
    end
    local proposed = shallowCopy(session)
    proposed.state = Constants.SESSION_STATE.Closed
    proposed.endMissionTime = endTime
    proposed.closeReason = reason
    local budgetDelta, budgetError = self:_replacementNeutralDelta(session, proposed)
    if budgetDelta == nil then
        return nil, budgetError
    end
    local budgeted, budgetReason = self:_preflightNeutralDelta(budgetDelta)
    if not budgeted then
        return nil, budgetReason
    end
    session.state = Constants.SESSION_STATE.Closed
    session.endMissionTime = endTime
    session.closeReason = reason
    self:_commitNeutralDelta(budgetDelta)
    local contextKey = self.contextKeyBySession[session.id]
    if contextKey ~= nil then
        if self.openSessionByContext[contextKey] == session.id then
            self.openSessionByContext[contextKey] = nil
        end
    end
    local rootVehicleId = self.rootKeyBySession[session.id] or session.rootVehicleId
    if rootVehicleId ~= nil and self.openSessionByRoot[rootVehicleId] == session.id then
        self.openSessionByRoot[rootVehicleId] = nil
    end
    self.contextKeyBySession[session.id] = nil
    self.rootKeyBySession[session.id] = nil
    self.lastEvidenceSequenceBySession[session.id] = nil
    self.lastEvidencePayloadBySession[session.id] = nil
    clearSegmentState(self, session.id)
    return self:_copyForCaller(session), true
end

function Ledger:expireSessions(missionTime)
    local now, timeError = validateMissionTime(missionTime)
    if now == nil then
        return nil, timeError
    end
    local closed = {}
    for _, sessionId in ipairs(self.sessionOrder) do
        local session = self.sessionsById[sessionId]
        if session.state == Constants.SESSION_STATE.Open
            and now - session.lastEvidenceTime >= Constants.STOP_GRACE_MS then
            local result, closeError = self:closeSession({
                sessionId = sessionId,
                reason = "evidenceTimeout",
                endMissionTime = now
            })
            if result == nil then
                return nil, closeError
            end
            closed[#closed + 1] = sessionId
        end
    end
    return closed
end

function Ledger:checkpointSessions(reason, missionTime)
    local now, timeError = validateMissionTime(missionTime)
    if now == nil then
        return nil, timeError
    end
    local closeReason, reasonError = validateToken(reason or "saveCheckpoint")
    if closeReason == nil then
        return nil, reasonError
    end
    for _, sessionId in ipairs(self.sessionOrder) do
        local session = self.sessionsById[sessionId]
        if session.state == Constants.SESSION_STATE.Open and now < session.lastEvidenceTime then
            return nil, "timeBeforeLastEvidence"
        end
    end
    local closed = {}
    for _, sessionId in ipairs(self.sessionOrder) do
        local session = self.sessionsById[sessionId]
        if session.state == Constants.SESSION_STATE.Open then
            local result, closeError = self:closeSession({
                sessionId = sessionId,
                reason = closeReason,
                endMissionTime = now
            })
            if result == nil then
                return nil, closeError
            end
            closed[#closed + 1] = sessionId
        end
    end
    return closed
end

function Ledger:checkpointCycleSessions(cycleId, reason, missionTime)
    local cycle = self.cyclesById[cycleId]
    if cycle == nil then
        return nil, "unknownCycle"
    end
    if cycle.state ~= Constants.CYCLE_STATE.Open then
        return nil, "openCycleRequired"
    end
    local now, timeError = validateMissionTime(missionTime)
    if now == nil then
        return nil, timeError
    end
    local closeReason, reasonError = validateToken(
        reason or "cycleBoundaryCheckpoint")
    if closeReason == nil then
        return nil, reasonError
    end
    local sessionIds = {}
    local totalDelta = 0
    for _, sessionId in ipairs(self.sessionOrder) do
        local session = self.sessionsById[sessionId]
        if session.cycleId == cycleId
            and session.state == Constants.SESSION_STATE.Open then
            if now < session.lastEvidenceTime then
                return nil, "timeBeforeLastEvidence"
            end
            local proposed = shallowCopy(session)
            proposed.state = Constants.SESSION_STATE.Closed
            proposed.endMissionTime = now
            proposed.closeReason = closeReason
            local delta, deltaError = self:_replacementNeutralDelta(
                session, proposed)
            if delta == nil then
                return nil, deltaError
            end
            totalDelta = totalDelta + delta
            sessionIds[#sessionIds + 1] = sessionId
        end
    end
    local budgeted, budgetReason = self:_preflightNeutralDelta(totalDelta)
    if not budgeted then
        return nil, budgetReason
    end
    local closed = {}
    for _, sessionId in ipairs(sessionIds) do
        local result, closeError = self:closeSession({
            sessionId = sessionId,
            reason = closeReason,
            endMissionTime = now
        })
        if result == nil then
            return nil, closeError
        end
        closed[#closed + 1] = sessionId
    end
    return closed
end

local function normalizeReferences(ledger, cycle, value)
    local array, arrayError = Core.Validation.array(value or {}, Constants.LIMITS.maxReferences)
    if array == nil then
        return nil, arrayError
    end
    local _, identifiers = dependencies()
    local result = {}
    local seen = {}
    for _, candidate in ipairs(array) do
        local reference, referenceError = validateToken(candidate, Constants.LIMITS.idBytes)
        if reference == nil then
            return nil, referenceError
        end
        local target = ledger.recordsById[reference] or ledger.sessionsById[reference]
        if target == nil then
            return nil, "unknownReference"
        end
        if target.cycleId ~= cycle.id then
            return nil, "crossCycleReferenceForbidden"
        end
        if not seen[reference] then
            seen[reference] = true
            result[#result + 1] = reference
        end
    end
    table.sort(result, function(left, right)
        return identifiers.compare(left, right) < 0
    end)
    return result
end

directTransactionKey = function(provenance)
    if provenance == nil then
        return nil
    end
    local parts = {
        string.format("%.0f", provenance.farmId),
        provenance.source,
        provenance.transactionId
    }
    if provenance.transactionGeneration ~= nil then
        parts[4] = string.format("%.0f", provenance.transactionGeneration)
    end
    return lengthPrefixed(parts)
end

local function validateRecordSession(ledger, cycle, sessionId, missionTime)
    if sessionId == nil then
        return nil, nil
    end
    local normalized, idError = validateToken(sessionId, Constants.LIMITS.idBytes)
    if normalized == nil then
        return nil, idError
    end
    local session = ledger.sessionsById[normalized]
    if session == nil then
        return nil, "unknownSession"
    end
    if session.cycleId ~= cycle.id then
        return nil, "sessionCycleMismatch"
    end
    if missionTime < session.firstEvidenceTime or missionTime > session.lastEvidenceTime then
        return nil, "recordOutsideSessionEvidence"
    end
    return session
end

local function normalizeDirectProvenance(command, cycle, session)
    if command.accountingClass ~= Constants.ACCOUNTING_CLASS.Direct
        or command.qualityClass == Constants.QUALITY_CLASS.Unsupported then
        if command.directProvenance ~= nil then
            return nil, "unexpectedDirectProvenance"
        end
        return nil, nil
    end
    if session == nil then
        return nil, "directSessionRequired"
    end
    local provenance = command.directProvenance
    if type(provenance) ~= "table" or provenance.authoritative ~= true then
        return nil, "directProvenanceRequired"
    end
    local source, sourceError = validateToken(provenance.source)
    if source == nil then
        return nil, sourceError
    end
    local transactionId, transactionError = validateToken(provenance.transactionId, Constants.LIMITS.idBytes)
    if transactionId == nil then
        return nil, transactionError
    end
    local farmId, farmError = validateInteger(provenance.farmId, 1, Constants.LIMITS.maxIdentifier)
    if farmId == nil then
        return nil, farmError
    end
    local transactionGeneration = nil
    if provenance.transactionGeneration ~= nil then
        transactionGeneration, transactionError = validateInteger(
            provenance.transactionGeneration,
            1,
            Constants.LIMITS.maxIdentifier
        )
        if transactionGeneration == nil then
            return nil, transactionError
        end
    end
    if farmId ~= cycle.farmId then
        return nil, "directFarmMismatch"
    end
    return {
        authoritative = true,
        source = source,
        transactionId = transactionId,
        transactionGeneration = transactionGeneration,
        farmId = farmId,
        sessionId = session.id
    }
end

local SEGMENT_ARRAY_FIELDS = {"leaseCandidates", "candidates"}

local function segmentBase(candidate)
    local base, copyError = neutralCopy(candidate)
    if base == nil then return nil, copyError end
    base.amount = nil
    base.missionTime = nil
    base.observationId = nil
    base.metadata.serverSequence = nil
    if base.metadata.unallocatedKind == "zeroChangedApplication" then
        -- These describe the exact topology observed by one callback rather
        -- than the semantic application segment.  A valid later callback may
        -- see more same-land consumers/sources, or the same fill name with a
        -- heterogeneous ID set, without changing the carrier operation.
        base.metadata.consumerCount = nil
        base.metadata.sourceCount = nil
        base.metadata.fillTypeId = nil
    end
    for _, field in ipairs(SEGMENT_ARRAY_FIELDS) do
        local rows = base.metadata[field]
        if type(rows) == "table" then
            for _, row in ipairs(rows) do
                if type(row) == "table" then row.activeOperatingMs = nil end
            end
        end
    end
    return base
end

local function exactTermSnapshot(term, maximum)
    local exactSum, exactError = exactSumDependency()
    if exactSum == nil then return nil, exactError end
    local accumulator = nil
    accumulator, exactError = exactSum.new(
        maximum, Constants.LIMITS.maxRecords)
    if accumulator == nil then return nil, exactError end
    local added = nil
    added, exactError = exactSum.add(accumulator, term)
    if not added then return nil, exactError end
    return exactSum.toNeutral(accumulator)
end

local function extendedExactTerm(snapshot, term, maximum)
    local exactSum, exactError = exactSumDependency()
    if exactSum == nil then return nil, nil, exactError end
    local accumulator = nil
    accumulator, exactError = exactSum.fromNeutral(
        snapshot, maximum, Constants.LIMITS.maxRecords)
    if accumulator == nil then return nil, nil, exactError end
    local added = nil
    added, exactError = exactSum.add(accumulator, term)
    if not added then return nil, nil, exactError end
    local amount = nil
    amount, exactError = exactSum.finish(accumulator, maximum)
    if amount == nil then return nil, nil, exactError end
    local proposedSnapshot = nil
    proposedSnapshot, exactError = exactSum.toNeutral(accumulator)
    if proposedSnapshot == nil then return nil, nil, exactError end
    return amount, proposedSnapshot
end

local function initialSegmentMetadataExactSums(metadata)
    local result = {}
    for _, field in ipairs(SEGMENT_ARRAY_FIELDS) do
        local rows = metadata[field]
        if type(rows) == "table" then
            local exactRows = {}
            result[field] = exactRows
            for index, row in ipairs(rows) do
                if type(row) == "table"
                    and type(row.activeOperatingMs) == "number" then
                    local exactError = nil
                    exactRows[index], exactError = exactTermSnapshot(
                        row.activeOperatingMs,
                        Constants.LIMITS.maxDurationMs)
                    if exactRows[index] == nil then return nil, exactError end
                end
            end
        end
    end
    return result
end

local function storedSegmentMetadata(metadata, sequence, missionTime)
    local stored, copyError = neutralCopy(metadata)
    if stored == nil then return nil, copyError end
    stored.serverSequence = nil
    stored.firstServerSequence = sequence
    stored.lastServerSequence = sequence
    stored.firstMissionTime = missionTime
    stored.lastMissionTime = missionTime
    stored.observationCount = 1
    return stored
end

local function extendedSegmentMetadata(
    current, incoming, sequence, missionTime, currentExactSums)
    local proposed, copyError = neutralCopy(current)
    if proposed == nil then return nil, nil, copyError end
    local proposedExactSums = {}
    proposed.lastServerSequence = sequence
    proposed.lastMissionTime = missionTime
    proposed.observationCount = proposed.observationCount + 1
    if proposed.observationCount > Constants.LIMITS.maxRecords then
        return nil, nil, "segmentObservationLimit"
    end
    if proposed.unallocatedKind == "zeroChangedApplication" then
        for _, field in ipairs({"consumerCount", "sourceCount"}) do
            local currentCount = validateInteger(
                proposed[field], 1, Constants.LIMITS.maxReferences)
            local incomingCount = validateInteger(
                incoming[field], 1, Constants.LIMITS.maxReferences)
            if currentCount == nil or incomingCount == nil then
                return nil, nil, "segmentMetadataCollision"
            end
            proposed[field] = math.max(currentCount, incomingCount)
        end
        -- Once more than one fill ID shape has been observed, nil remains the
        -- honest aggregate for the rest of the segment.
        if proposed.fillTypeId ~= incoming.fillTypeId then
            proposed.fillTypeId = nil
        end
    end
    for _, field in ipairs(SEGMENT_ARRAY_FIELDS) do
        local targets = proposed[field]
        local sources = incoming[field]
        if type(targets) == "table" and type(sources) == "table" then
            if #targets ~= #sources then
                return nil, nil, "segmentMetadataCollision"
            end
            local currentExactRows = type(currentExactSums) == "table"
                and currentExactSums[field] or nil
            if type(currentExactRows) ~= "table" then
                return nil, nil, "segmentStateCorrupt"
            end
            local proposedExactRows = {}
            proposedExactSums[field] = proposedExactRows
            for index, target in ipairs(targets) do
                local source = sources[index]
                if type(target) ~= "table" or type(source) ~= "table"
                    or type(target.activeOperatingMs) ~= "number"
                    or type(source.activeOperatingMs) ~= "number" then
                    return nil, nil, "segmentMetadataCollision"
                end
                if type(currentExactRows[index]) ~= "table" then
                    return nil, nil, "segmentStateCorrupt"
                end
                local amount = nil
                amount, proposedExactRows[index], copyError = extendedExactTerm(
                    currentExactRows[index],
                    source.activeOperatingMs,
                    Constants.LIMITS.maxDurationMs)
                if amount == nil then return nil, nil, copyError end
                target.activeOperatingMs = amount
            end
        elseif targets ~= nil or sources ~= nil then
            return nil, nil, "segmentMetadataCollision"
        end
    end
    return proposed, proposedExactSums
end

local function segmentEvent(candidate, recordId)
    local event, copyError = neutralCopy(candidate)
    if event == nil then return nil, copyError end
    event.id = recordId
    return event
end

function Ledger:acceptRecord(command)
    if type(command) ~= "table" then
        return nil, "invalidCommand"
    end
    if rawget(command, "actualProfit") ~= nil or rawget(command, "realizedProfit") ~= nil then
        return nil, "reservedProfitField"
    end
    local cycle = self.cyclesById[command.cycleId]
    if cycle == nil then
        return nil, "unknownCycle"
    end
    if cycle.state ~= Constants.CYCLE_STATE.Open then
        return nil, "openCycleRequired"
    end
    local recordType, typeError = validateToken(command.recordType)
    if recordType == nil or not Constants.RECORD_TYPE_SET[recordType]
        or recordType == Constants.RECORD_TYPE.Summary then
        return nil, typeError or "invalidRecordType"
    end
    local category, categoryError = validateToken(command.category)
    if category == nil then
        return nil, categoryError
    end
    local accountingClass = command.accountingClass
    if not Constants.ACCOUNTING_CLASS_SET[accountingClass] then
        return nil, "invalidAccountingClass"
    end
    local qualityClass = command.qualityClass
    if not Constants.QUALITY_CLASS_SET[qualityClass] then
        return nil, "invalidQualityClass"
    end
    local missionTime, timeError = validateMissionTime(command.missionTime)
    if missionTime == nil then
        return nil, timeError
    end
    if missionTime < cycle.startMissionTime then
        return nil, "timeBeforeCycleStart"
    end
    local _, identifiers, identifierError = dependencies()
    if identifierError ~= nil then
        return nil, identifierError
    end
    local observationParts = identifiers.parseObservationId(command.observationId)
    if observationParts == nil then
        return nil, "invalidObservationId"
    end
    if self._loadingNeutral ~= true and observationParts.epoch ~= self.epoch then
        return nil, "observationEpochMismatch"
    end
    local observationId = command.observationId
    local unit = nil
    local amount = nil
    if qualityClass == Constants.QUALITY_CLASS.Unsupported then
        if command.amount ~= nil then
            return nil, "unsupportedAmountMustBeAbsent"
        end
        if command.unit ~= nil then
            return nil, "unsupportedUnitMustBeAbsent"
        end
    else
        unit, typeError = validateToken(command.unit)
        if unit == nil or not Constants.UNIT_SET[unit] then
            return nil, typeError or "invalidUnit"
        end
        if accountingClass == Constants.ACCOUNTING_CLASS.Observed and unit == Constants.UNIT.Money then
            return nil, "observedMoneyForbidden"
        end
        if accountingClass ~= Constants.ACCOUNTING_CLASS.Observed and unit ~= Constants.UNIT.Money then
            return nil, "monetaryClassRequiresMoneyUnit"
        end
        amount, timeError = validateStoredAmount(command.amount, unit)
        if amount == nil then
            return nil, timeError
        end
    end
    local direction, directionError = validateDirection(accountingClass, qualityClass, command.direction)
    if directionError ~= nil then
        return nil, directionError
    end
    local reasons, reasonsError = normalizeReasons(command.reasons)
    if reasons == nil then
        return nil, reasonsError
    end
    if qualityClass ~= Constants.QUALITY_CLASS.Complete and #reasons == 0 then
        return nil, "qualityReasonRequired"
    end
    local session, sessionError = validateRecordSession(self, cycle, command.sessionId, missionTime)
    if sessionError ~= nil then
        return nil, sessionError
    end
    local metadata, metadataError = normalizeMetadata(command.metadata)
    if metadata == nil then
        return nil, metadataError
    end
    if containsReservedField(metadata) then
        return nil, "reservedProfitField"
    end
    local unallocated, markerError, unallocatedKind = unallocatedRecordMarker({
        cycleId = cycle.id,
        landKey = cycle.landKey,
        sessionId = session and session.id or nil,
        recordType = recordType,
        category = category,
        accountingClass = accountingClass,
        qualityClass = qualityClass,
        amount = amount,
        unit = unit,
        reasons = reasons,
        metadata = metadata
    }, self)
    if unallocated == nil then
        return nil, markerError
    end
    if session ~= nil
        and session.carrierKind == ZERO_CHANGED_APPLICATION_CARRIER_KIND
        and unallocatedKind ~= ZERO_CHANGED_APPLICATION_CARRIER_KIND then
        return nil, "carrierRecordForbidden"
    end
    if unallocatedKind == "mixedBoundary" then
        metadata, metadataError = normalizeMixedBoundaryMetadata(metadata, cycle.farmId)
        if metadata == nil then
            return nil, metadataError
        end
        qualityClass = lowerQuality(qualityClass, Constants.QUALITY_CLASS.Partial)
        reasons, reasonsError = mergeReasons(reasons, {"boundaryUnresolved"})
        if reasons == nil then
            return nil, reasonsError
        end
    elseif unallocatedKind == "zeroChangedApplication" then
        metadata = normalizeZeroChangedApplicationMetadata(metadata)
    end
    local references, referencesError = normalizeReferences(self, cycle, command.references)
    if references == nil then
        return nil, referencesError
    end
    if unallocatedKind == ZERO_CHANGED_APPLICATION_CARRIER_KIND
        and #references ~= 0 then
        return nil, "zeroChangedApplicationReferencesForbidden"
    end
    local basisId, basisError = validateOptionalToken(command.basisId, Constants.LIMITS.idBytes)
    if basisError ~= nil then
        return nil, basisError
    end
    local directProvenance, provenanceError = normalizeDirectProvenance(command, cycle, session)
    if provenanceError ~= nil then
        return nil, provenanceError
    end
    local segmentToken, segmentError = validateOptionalToken(
        rawget(command, "segmentKey"), Constants.LIMITS.idBytes)
    if segmentError ~= nil then return nil, segmentError end
    if segmentToken ~= nil and session == nil then
        return nil, "segmentSessionRequired"
    end
    if segmentToken ~= nil and directProvenance ~= nil then
        return nil, "directSegmentForbidden"
    end
    local candidate = {
        cycleId = cycle.id,
        landKey = cycle.landKey,
        sessionId = session and session.id or nil,
        recordType = recordType,
        category = category,
        accountingClass = accountingClass,
        qualityClass = qualityClass,
        amount = amount,
        unit = unit,
        direction = direction,
        missionTime = missionTime,
        observationId = observationId,
        basisId = basisId,
        directProvenance = directProvenance,
        reasons = reasons,
        metadata = metadata,
        references = references
    }
    local segmentKey = segmentToken ~= nil
        and lengthPrefixed({session.id, segmentToken}) or nil
    local segmentState = segmentKey ~= nil
        and self._segmentStatesByKey[segmentKey] or nil
    local observationStreamKey = segmentObservationStreamKey(observationParts)
    if segmentState ~= nil then
        local persistedOwner = self.observationIndex[observationId]
        if persistedOwner ~= nil
            and persistedOwner ~= segmentState.recordId then
            return nil, "observationCollision"
        end
        local stream =
            self._segmentObservationStreamsByKey[observationStreamKey]
        if stream ~= nil and stream.recordId ~= nil
            and stream.recordId ~= segmentState.recordId then
            return nil, "observationCollision"
        end
        if segmentState.streamKey ~= observationStreamKey then
            return nil, "segmentCollision"
        end
        if stream == nil
            or stream.recordId ~= segmentState.recordId
            or stream.sessionId ~= session.id
            or stream.segmentKey ~= segmentKey
            or stream.lastSequence ~= segmentState.lastSequence
            or self._segmentStreamKeyByRecordId[segmentState.recordId]
                ~= observationStreamKey then
            return nil, "segmentStateCorrupt"
        end
        if observationId == segmentState.lastObservationId then
            if not neutralEqual(candidate, segmentState.lastEvent) then
                return nil, "observationCollision"
            end
            return segmentEvent(candidate, segmentState.recordId), false,
                "duplicateObservation"
        end
        if observationId == segmentState.firstObservationId then
            if not neutralEqual(candidate, segmentState.firstEvent) then
                return nil, "observationCollision"
            end
            return segmentEvent(candidate, segmentState.recordId), false,
                "duplicateObservation"
        end
        if observationParts.sequence <= segmentState.lastSequence
            or observationParts.sequence <= stream.lastSequence
            or missionTime < segmentState.lastMissionTime then
            return nil, "outOfOrderSegmentObservation"
        end
        local base, baseError = segmentBase(candidate)
        if base == nil then return nil, baseError end
        if not neutralEqual(base, segmentState.base) then
            return nil, "segmentCollision"
        end
        local stored = self.recordsById[segmentState.recordId]
        if stored == nil or stored.sessionId ~= session.id then
            return nil, "segmentStateCorrupt"
        end
        local proposed = shallowCopy(stored)
        local proposedMetadataExactSums = nil
        proposed.metadata, proposedMetadataExactSums, baseError =
            extendedSegmentMetadata(
            stored.metadata, candidate.metadata,
            observationParts.sequence, missionTime,
            segmentState.metadataExactSums)
        if proposed.metadata == nil then return nil, baseError end
        proposed.missionTime = missionTime
        local proposedAmountExactSum = segmentState.amountExactSum
        if amount ~= nil then
            if type(segmentState.amountExactSum) ~= "table" then
                return nil, "segmentStateCorrupt"
            end
            proposed.amount, proposedAmountExactSum, baseError =
                extendedExactTerm(
                    segmentState.amountExactSum,
                    amount,
                    amountLimitForUnit(unit))
            if proposed.amount == nil then return nil, baseError end
        end
        local categoryKey, categoryState, rebuiltCategoryStates = nil, nil, nil
        local segmentExcluded = self.excludedTargets[stored.id] ~= nil
            or (stored.sessionId ~= nil
                and self.excludedTargets[stored.sessionId] ~= nil)
        local boundaryEvidence = self._cycleBoundaryEvidenceByCycle[cycle.id]
        if boundaryEvidence == nil then
            local rebuilt, rebuildReason =
                self:_rebuildCycleQueryIndexes(cycle.id)
            if not rebuilt then return nil, rebuildReason end
            boundaryEvidence = self._cycleBoundaryEvidenceByCycle[cycle.id]
        end
        if self._loadingNeutral ~= true and amount ~= nil and not unallocated
                and not segmentExcluded then
            categoryKey, categoryState, rebuiltCategoryStates =
                self:_prepareCategoryDelta(candidate, {amount}, 0)
            if categoryState == nil then
                return nil, rebuiltCategoryStates
            end
        end
        local budgetDelta, budgetError =
            self:_replacementNeutralDelta(stored, proposed)
        if budgetDelta == nil then return nil, budgetError end
        local budgeted, budgetReason = self:_preflightNeutralDelta(budgetDelta)
        if not budgeted then return nil, budgetReason end
        stored.amount = proposed.amount
        stored.missionTime = proposed.missionTime
        stored.metadata = proposed.metadata
        self.lastActivityTimeByCycle[cycle.id] = math.max(
            self.lastActivityTimeByCycle[cycle.id] or missionTime,
            missionTime)
        boundaryEvidence.lastActivityMissionTime =
            self.lastActivityTimeByCycle[cycle.id]
        if stored.recordType == Constants.RECORD_TYPE.Harvest
                and stored.category == Constants.CATEGORY.harvest
                and not unallocated and not segmentExcluded
                and boundaryHarvestIsNewer(
                    boundaryEvidence, missionTime, stored.id) then
            boundaryEvidence.hasHarvest = true
            boundaryEvidence.lastHarvestMissionTime = missionTime
            boundaryEvidence.lastHarvestRecordId = stored.id
        end
        self:_commitNeutralDelta(budgetDelta)
        if categoryState ~= nil then
            self:_commitCategoryState(
                cycle.id, categoryKey, categoryState, rebuiltCategoryStates)
        end
        stream.lastSequence = observationParts.sequence
        segmentState.lastObservationId = observationId
        segmentState.lastEvent = candidate
        segmentState.lastSequence = observationParts.sequence
        segmentState.lastMissionTime = missionTime
        segmentState.amountExactSum = proposedAmountExactSum
        segmentState.metadataExactSums = proposedMetadataExactSums
        self:_touchReport(cycle.id)
        return segmentEvent(candidate, segmentState.recordId), true
    end
    local priorSegmentStream =
        self._segmentObservationStreamsByKey[observationStreamKey]
    if priorSegmentStream ~= nil
        and (observationId == priorSegmentStream.firstObservationId
            or observationId == priorSegmentStream.lastObservationId) then
        local priorRecord = self.recordsById[priorSegmentStream.recordId]
        local priorSession = self.sessionsById[priorSegmentStream.sessionId]
        local endpointEvent = observationId
                == priorSegmentStream.firstObservationId
            and priorSegmentStream.firstEvent
            or priorSegmentStream.lastEvent
        if priorRecord == nil or priorSession == nil
            or priorRecord.sessionId ~= priorSession.id
            or priorSession.state ~= Constants.SESSION_STATE.Closed
            or priorSegmentStream.segmentKey == nil
            or self._segmentStreamKeyByRecordId[priorRecord.id]
                ~= observationStreamKey
            or type(endpointEvent) ~= "table" then
            return nil, "segmentStateCorrupt"
        end
        if segmentKey ~= priorSegmentStream.segmentKey
            or not neutralEqual(candidate, endpointEvent) then
            return nil, "observationCollision"
        end
        return segmentEvent(candidate, priorRecord.id), false,
            "duplicateObservation"
    end
    local duplicateId = self.observationIndex[observationId]
    if duplicateId ~= nil then
        local duplicate = self.recordsById[duplicateId]
        local comparable = shallowCopy(duplicate)
        comparable.id = nil
        if not neutralEqual(comparable, candidate) then
            return nil, "observationCollision"
        end
        return self:getRecord(duplicateId), false, "duplicateObservation"
    end
    if priorSegmentStream ~= nil then
        if type(priorSegmentStream.lastSequence) ~= "number"
            or priorSegmentStream.lastSequence
                ~= math.floor(priorSegmentStream.lastSequence) then
            return nil, "segmentStateCorrupt"
        end
        if segmentKey == nil
            or observationParts.sequence
                <= priorSegmentStream.lastSequence then
            return nil, "observationCollision"
        end
    end
    local replacedSegmentStreamRecordId = nil
    if segmentKey ~= nil and priorSegmentStream ~= nil then
        replacedSegmentStreamRecordId = priorSegmentStream.recordId
        if replacedSegmentStreamRecordId ~= nil then
            local priorRecord =
                self.recordsById[replacedSegmentStreamRecordId]
            local priorSession =
                self.sessionsById[priorSegmentStream.sessionId]
            if priorRecord == nil or priorSession == nil
                or priorRecord.sessionId ~= priorSegmentStream.sessionId
                or priorSegmentStream.segmentKey == nil
                or self._segmentStreamKeyByRecordId[
                    replacedSegmentStreamRecordId] ~= observationStreamKey then
                return nil, "segmentStateCorrupt"
            end
            if priorSession.id == session.id then
                return nil, "segmentStateCorrupt"
            end
            if priorSession.state ~= Constants.SESSION_STATE.Closed then
                return nil, "observationCollision"
            end
        elseif priorSegmentStream.sessionId ~= nil
            or priorSegmentStream.segmentKey ~= nil then
            return nil, "segmentStateCorrupt"
        end
    end
    local transactionKey = directTransactionKey(directProvenance)
    if transactionKey ~= nil and self.directTransactionIndex[transactionKey] ~= nil then
        return nil, "directTransactionCollision"
    end
    local eventCandidate = nil
    local segmentBaseValue = nil
    local segmentAmountExactSum = nil
    local segmentMetadataExactSums = nil
    if segmentKey ~= nil then
        eventCandidate, segmentError = neutralCopy(candidate)
        if eventCandidate == nil then return nil, segmentError end
        segmentBaseValue, segmentError = segmentBase(candidate)
        if segmentBaseValue == nil then return nil, segmentError end
        if amount ~= nil then
            segmentAmountExactSum, segmentError = exactTermSnapshot(
                amount, amountLimitForUnit(unit))
            if segmentAmountExactSum == nil then return nil, segmentError end
        end
        segmentMetadataExactSums, segmentError =
            initialSegmentMetadataExactSums(candidate.metadata)
        if segmentMetadataExactSums == nil then return nil, segmentError end
        candidate.metadata, segmentError = storedSegmentMetadata(
            candidate.metadata, observationParts.sequence, missionTime)
        if candidate.metadata == nil then return nil, segmentError end
    end
    local categoryKey = nil
    local categoryState = nil
    local rebuiltCategoryStates = nil
    if self._loadingNeutral ~= true and amount ~= nil and not unallocated then
        categoryKey, categoryState, rebuiltCategoryStates =
            self:_prepareCategoryDelta(candidate, {amount}, 1)
        if categoryState == nil then
            return nil, rebuiltCategoryStates
        end
    end
    local previewId, idError = self:_previewId("record")
    if previewId == nil then
        return nil, idError
    end
    local record = candidate
    record.id = previewId
    local recordItems, countError = neutralItemCount(record)
    if recordItems == nil then
        record.id = nil
        return nil, countError
    end
    local budgeted, budgetReason = self:_preflightNeutralDelta(recordItems)
    if not budgeted then
        record.id = nil
        return nil, budgetReason
    end
    local id = nil
    id, idError = self:_allocateId("record")
    if id == nil then
        record.id = nil
        return nil, idError
    end
    if id ~= previewId then
        record.id = nil
        return nil, "identifierAllocationChanged"
    end
    self.recordsById[id] = record
    self.recordOrder[#self.recordOrder + 1] = id
    self._recordIdsByCycle[cycle.id] = self._recordIdsByCycle[cycle.id] or {}
    self._recordIdsByCycle[cycle.id][#self._recordIdsByCycle[cycle.id] + 1] = id
    self._includedRecordIdsByCycle[cycle.id] =
        self._includedRecordIdsByCycle[cycle.id] or {}
    self._includedRecordIdsByCycle[cycle.id][
        #self._includedRecordIdsByCycle[cycle.id] + 1] = id
    local boundaryEvidence = self._cycleBoundaryEvidenceByCycle[cycle.id]
    if boundaryEvidence == nil then
        boundaryEvidence = {hasHarvest=false}
        self._cycleBoundaryEvidenceByCycle[cycle.id] = boundaryEvidence
    end
    boundaryEvidence.lastActivityMissionTime = math.max(
        boundaryEvidence.lastActivityMissionTime or missionTime,
        missionTime)
    if record.recordType == Constants.RECORD_TYPE.Harvest
            and record.category == Constants.CATEGORY.harvest
            and not unallocated
            and boundaryHarvestIsNewer(
                boundaryEvidence, missionTime, id) then
        boundaryEvidence.hasHarvest = true
        boundaryEvidence.lastHarvestMissionTime = missionTime
        boundaryEvidence.lastHarvestRecordId = id
    end
    self.observationIndex[observationId] = id
    if transactionKey ~= nil then
        self.directTransactionIndex[transactionKey] = id
    end
    self.lastActivityTimeByCycle[cycle.id] = math.max(
        self.lastActivityTimeByCycle[cycle.id] or missionTime,
        missionTime
    )
    self:_commitNeutralDelta(recordItems)
    if categoryState ~= nil then
        self:_commitCategoryState(
            cycle.id,
            categoryKey,
            categoryState,
            rebuiltCategoryStates
        )
    end
    local queryState = self._queryStateByCycle[cycle.id]
    if queryState == nil then
        queryState = {qualityCounts={
            [Constants.QUALITY_CLASS.Complete]=0,
            [Constants.QUALITY_CLASS.Partial]=0,
            [Constants.QUALITY_CLASS.Unsupported]=0},
            directReplacementOverlap=false, basisClasses={}}
        self._queryStateByCycle[cycle.id] = queryState
    end
    queryState.qualityCounts[record.qualityClass] =
        (queryState.qualityCounts[record.qualityClass] or 0) + 1
    queryState.basisClasses = queryState.basisClasses or {}
    if not unallocated and record.basisId ~= nil
        and (record.accountingClass == Constants.ACCOUNTING_CLASS.Direct
            or record.accountingClass == Constants.ACCOUNTING_CLASS.Valued) then
        local classes = queryState.basisClasses[record.basisId] or {}
        classes[record.accountingClass] = true
        queryState.basisClasses[record.basisId] = classes
        if classes[Constants.ACCOUNTING_CLASS.Direct]
            and classes[Constants.ACCOUNTING_CLASS.Valued] then
            queryState.directReplacementOverlap = true
        end
    end
    if segmentKey ~= nil then
        local stream = priorSegmentStream
        if stream == nil then
            stream = {}
            self._segmentObservationStreamsByKey[observationStreamKey] = stream
        elseif replacedSegmentStreamRecordId ~= nil then
            self._segmentStreamKeyByRecordId[
                replacedSegmentStreamRecordId] = nil
        end
        clearSegmentReplay(stream)
        stream.lastSequence = observationParts.sequence
        stream.recordId = id
        stream.sessionId = session.id
        stream.segmentKey = segmentKey
        self._segmentStreamKeyByRecordId[id] = observationStreamKey
        local state = {
            base = segmentBaseValue,
            firstEvent = eventCandidate,
            firstObservationId = observationId,
            lastEvent = eventCandidate,
            lastObservationId = observationId,
            lastMissionTime = missionTime,
            lastSequence = observationParts.sequence,
            recordId = id,
            streamKey = observationStreamKey,
            -- ExactSum neutral states are runtime-only and advance only after
            -- the corresponding canonical record/category commit succeeds.
            amountExactSum = segmentAmountExactSum,
            metadataExactSums = segmentMetadataExactSums
        }
        self._segmentStatesByKey[segmentKey] = state
        local keys = self._segmentKeysBySession[session.id]
        if keys == nil then
            keys = {}
            self._segmentKeysBySession[session.id] = keys
        end
        keys[#keys + 1] = segmentKey
    end
    self:_touchReport(cycle.id)
    if segmentKey ~= nil then
        return segmentEvent(eventCandidate, id), true
    end
    return self:_copyForCaller(record), true
end

function Ledger:getRecord(recordId)
    local record = self.recordsById[recordId]
    if record == nil then
        return nil, "unknownRecord"
    end
    return self:_copyForCaller(record)
end

function Ledger:_exactAmountAccumulator(recordId)
    local record = self.recordsById[recordId]
    if record == nil then
        return nil, "unknownRecord"
    end
    local amount = record.amount
    if amount == nil then
        return nil, "recordHasNoAmount"
    end
    local maximum = amountLimitForUnit(record.unit)
    if maximum == nil then
        return nil, "invalidTargetUnit"
    end
    local exactSum, exactError = exactSumDependency()
    if exactSum == nil then
        return nil, exactError
    end
    local accumulator = nil
    accumulator, exactError = exactSum.new(maximum, Constants.LIMITS.maxRecords)
    if accumulator == nil then
        return nil, exactError
    end
    local accepted = nil
    accepted, exactError = exactSum.add(accumulator, amount)
    if not accepted then
        return nil, exactError
    end
    for _, correctionId in ipairs(self.correctionsByTarget[recordId] or {}) do
        local correction = self.correctionsById[correctionId]
        if correction == nil then
            return nil, "danglingCorrection"
        end
        accepted, exactError = exactSum.add(accumulator, correction.delta)
        if not accepted then
            return nil, exactError
        end
    end
    return accumulator, maximum
end

function Ledger:_adjustedAmount(recordId)
    local accumulator, maximumOrError = self:_exactAmountAccumulator(recordId)
    if accumulator == nil then
        return nil, maximumOrError
    end
    local exactSum, exactError = exactSumDependency()
    if exactSum == nil then
        return nil, exactError
    end
    return exactSum.finish(accumulator, maximumOrError)
end

local function recordChronologyStart(record)
    local earliest = record.missionTime
    if type(record.metadata) ~= "table" then return earliest end
    local firstMissionTime = validateMissionTime(
        rawget(record.metadata, "firstMissionTime"))
    local lastMissionTime = validateMissionTime(
        rawget(record.metadata, "lastMissionTime"))
    local observationCount = validateInteger(
        rawget(record.metadata, "observationCount"),
        1, Constants.LIMITS.maxRecords)
    if firstMissionTime ~= nil and lastMissionTime ~= nil
            and observationCount ~= nil
            and firstMissionTime <= lastMissionTime
            and lastMissionTime == record.missionTime then
        -- Coalesced records advance missionTime with later callbacks. The
        -- immutable firstMissionTime remains the chronology boundary for
        -- audit annotations already appended to that segment.
        return firstMissionTime
    end
    return earliest
end

function Ledger:appendCorrection(command)
    if type(command) ~= "table" then
        return nil, "invalidCommand"
    end
    local target = self.recordsById[command.targetId]
    if target == nil then
        return nil, "unknownRecord"
    end
    local targetLimit = amountLimitForUnit(target.unit)
    if targetLimit == nil then
        return nil, "invalidTargetUnit"
    end
    local delta, deltaError = validateNumber(command.delta, -targetLimit, targetLimit)
    if delta == nil or delta == 0 then
        return nil, deltaError or "zeroCorrection"
    end
    local accumulator, accumulatorError = self:_exactAmountAccumulator(command.targetId)
    if accumulator == nil then
        return nil, accumulatorError
    end
    local exactSum, exactError = exactSumDependency()
    if exactSum == nil then
        return nil, exactError
    end
    local accepted = nil
    accepted, exactError = exactSum.add(accumulator, delta)
    if not accepted then
        return nil, exactError
    end
    local corrected = nil
    corrected, exactError = exactSum.finish(accumulator, targetLimit)
    if corrected == nil or corrected < 0 then
        if exactError == nil or exactError == "aggregateOutOfRange" then
            return nil, "correctedTotalOutOfRange"
        end
        return nil, exactError
    end
    if corrected > targetLimit then
        return nil, "correctedTotalOutOfRange"
    end
    local reason, reasonError = validateNonEmptyText(
        command.reason,
        Constants.LIMITS.textBytes,
        "emptyCorrectionReason"
    )
    if reason == nil then
        return nil, reasonError
    end
    local authorFarmId, farmError = validateInteger(command.authorFarmId, 1, Constants.LIMITS.maxIdentifier)
    if authorFarmId == nil then
        return nil, farmError
    end
    local cycle = self.cyclesById[target.cycleId]
    if cycle == nil or cycle.farmId ~= authorFarmId then
        return nil, "farmAuthorityMismatch"
    end
    local authorUserId, authorError = validateOptionalToken(command.authorUserId, Constants.LIMITS.idBytes)
    if authorError ~= nil then
        return nil, authorError
    end
    local missionTime, timeError = validateMissionTime(command.missionTime)
    if missionTime == nil then
        return nil, timeError
    end
    local correctionEarliest = target.missionTime
    if self._loadingNeutral == true then
        correctionEarliest = recordChronologyStart(target)
    end
    if missionTime < correctionEarliest then
        return nil, "correctionBeforeObservation"
    end
    local categoryKey = nil
    local categoryState = nil
    local rebuiltCategoryStates = nil
    if self._loadingNeutral ~= true then
        local unallocated, markerError = unallocatedRecordMarker(target, self)
        if unallocated == nil then
            return nil, markerError
        end
        local excluded = self.excludedTargets[target.id] ~= nil
            or (target.sessionId ~= nil
                and self.excludedTargets[target.sessionId] ~= nil)
        if not excluded and not unallocated then
            categoryKey, categoryState, rebuiltCategoryStates =
                self:_prepareCategoryDelta(target, {delta}, 0)
            if categoryState == nil then
                return nil, rebuiltCategoryStates
            end
        end
    end
    local id, idError = self:_previewId("correction")
    if id == nil then
        return nil, idError
    end
    local correction = {
        id = id,
        targetId = command.targetId,
        delta = delta,
        unit = target.unit,
        category = target.category,
        authorFarmId = authorFarmId,
        authorUserId = authorUserId,
        missionTime = missionTime,
        reason = reason
    }
    local correctionItems, countError = neutralItemCount(correction)
    if correctionItems == nil then
        return nil, countError
    end
    local budgeted, budgetReason = self:_preflightNeutralDelta(correctionItems)
    if not budgeted then
        return nil, budgetReason
    end
    local allocatedId = nil
    allocatedId, idError = self:_allocateId("correction")
    if allocatedId == nil then
        return nil, idError
    end
    if allocatedId ~= id then
        return nil, "identifierAllocationChanged"
    end
    self.correctionsById[id] = correction
    self.correctionOrder[#self.correctionOrder + 1] = id
    self.correctionsByTarget[target.id] = self.correctionsByTarget[target.id] or {}
    self.correctionsByTarget[target.id][#self.correctionsByTarget[target.id] + 1] = id
    self._correctionIdsByCycle[target.cycleId] =
        self._correctionIdsByCycle[target.cycleId] or {}
    self._correctionIdsByCycle[target.cycleId][
        #self._correctionIdsByCycle[target.cycleId] + 1] = id
    self:_commitNeutralDelta(correctionItems)
    if categoryState ~= nil then
        self:_commitCategoryState(
            target.cycleId,
            categoryKey,
            categoryState,
            rebuiltCategoryStates
        )
    end
    self:_touchReport(target.cycleId)
    return self:_copyForCaller(correction)
end

function Ledger:appendExclusion(command)
    if type(command) ~= "table" then
        return nil, "invalidCommand"
    end
    local targetKind = nil
    local target = self.recordsById[command.targetId]
    if target ~= nil then
        targetKind = "record"
    else
        target = self.sessionsById[command.targetId]
        if target ~= nil then
            targetKind = "session"
        end
    end
    if target == nil then
        return nil, "unknownExclusionTarget"
    end
    if command.targetKind ~= nil and command.targetKind ~= targetKind then
        return nil, "exclusionTargetKindMismatch"
    end
    if targetKind == "session" and target.state == Constants.SESSION_STATE.Open then
        return nil, "openSessionExclusionForbidden"
    end
    if self.excludedTargets[command.targetId] ~= nil then
        return nil, "alreadyExcluded"
    end
    local reason, reasonError = validateNonEmptyText(
        command.reason,
        Constants.LIMITS.textBytes,
        "emptyExclusionReason"
    )
    if reason == nil then
        return nil, reasonError
    end
    local authorFarmId, farmError = validateInteger(command.authorFarmId, 1, Constants.LIMITS.maxIdentifier)
    if authorFarmId == nil then
        return nil, farmError
    end
    local cycle = self.cyclesById[target.cycleId]
    if cycle == nil or cycle.farmId ~= authorFarmId then
        return nil, "farmAuthorityMismatch"
    end
    local authorUserId, authorError = validateOptionalToken(command.authorUserId, Constants.LIMITS.idBytes)
    if authorError ~= nil then
        return nil, authorError
    end
    local missionTime, timeError = validateMissionTime(command.missionTime)
    if missionTime == nil then
        return nil, timeError
    end
    local earliest = targetKind == "record"
        and target.missionTime or target.lastEvidenceTime
    if self._loadingNeutral == true and targetKind == "record" then
        earliest = recordChronologyStart(target)
    end
    if missionTime < earliest then
        return nil, "exclusionBeforeTarget"
    end
    local id, idError = self:_previewId("exclusion")
    if id == nil then
        return nil, idError
    end
    local exclusion = {
        id = id,
        targetId = command.targetId,
        targetKind = targetKind,
        authorFarmId = authorFarmId,
        authorUserId = authorUserId,
        missionTime = missionTime,
        reason = reason
    }
    local exclusionItems, countError = neutralItemCount(exclusion)
    if exclusionItems == nil then
        return nil, countError
    end
    local budgeted, budgetReason = self:_preflightNeutralDelta(exclusionItems)
    if not budgeted then
        return nil, budgetReason
    end
    local rebuiltCategoryStates = nil
    if self._loadingNeutral ~= true then
        local categoryError = nil
        rebuiltCategoryStates, categoryError = buildCategoryStates(
            self,
            target.cycleId,
            nil,
            command.targetId
        )
        if rebuiltCategoryStates == nil then
            return nil, categoryError
        end
    end
    local allocatedId = nil
    allocatedId, idError = self:_allocateId("exclusion")
    if allocatedId == nil then
        return nil, idError
    end
    if allocatedId ~= id then
        return nil, "identifierAllocationChanged"
    end
    self.exclusionsById[id] = exclusion
    self.exclusionOrder[#self.exclusionOrder + 1] = id
    self.excludedTargets[command.targetId] = id
    self:_commitNeutralDelta(exclusionItems)
    if rebuiltCategoryStates ~= nil then
        self.categoryStatesByCycle[target.cycleId] = rebuiltCategoryStates
    end
    local rebuilt, rebuildReason = self:_rebuildCycleQueryIndexes(target.cycleId)
    if not rebuilt then return nil, rebuildReason end
    self:_touchReport(target.cycleId)
    return self:_copyForCaller(exclusion)
end

function Ledger:setAlias(landKey, alias)
    local parts, landError = validateLandKey(landKey)
    if parts == nil then
        return nil, landError
    end
    local value, valueError = validateNonEmptyText(
        alias,
        Constants.LIMITS.textBytes,
        "emptyAlias"
    )
    if value == nil then
        return nil, valueError
    end
    local budgetDelta = self.aliases[landKey] == nil and 1 or 0
    local budgeted, budgetReason = self:_preflightNeutralDelta(budgetDelta)
    if not budgeted then
        return nil, budgetReason
    end
    local changed = self.aliases[landKey] ~= value
    self.aliases[landKey] = value
    self:_commitNeutralDelta(budgetDelta)
    if changed then
        local touched = false
        for _, cycleId in ipairs(self.cycleOrder) do
            local cycle = self.cyclesById[cycleId]
            if cycle ~= nil and cycle.landKey == landKey then
                self:_touchReport(cycleId)
                touched = true
            end
        end
        if not touched then self:_touchReport(nil) end
    end
    return value
end

function Ledger:getAlias(landKey)
    local parts, landError = validateLandKey(landKey)
    if parts == nil then
        return nil, landError
    end
    local alias = self.aliases[landKey]
    if alias == nil then
        return nil, "aliasNotFound"
    end
    return alias
end

function Ledger:setGroup(groupId, landKeys)
    local id, idError = validateToken(groupId, Constants.LIMITS.idBytes)
    if id == nil then
        return nil, idError
    end
    local array, arrayError = Core.Validation.array(landKeys, Constants.LIMITS.maxReferences)
    if array == nil then
        return nil, arrayError
    end
    if #array == 0 then
        return nil, "emptyGroup"
    end
    local seen = {}
    local result = {}
    local groupFarmId = nil
    for _, landKey in ipairs(array) do
        local parts, landError = validateLandKey(landKey)
        if parts == nil then
            return nil, landError
        end
        if groupFarmId == nil then
            groupFarmId = parts.farmId
        elseif groupFarmId ~= parts.farmId then
            return nil, "crossFarmGroupForbidden"
        end
        if not seen[landKey] then
            seen[landKey] = true
            result[#result + 1] = landKey
        end
    end
    table.sort(result, byteLess)
    local group = {
        farmId = groupFarmId,
        landKeys = result
    }
    local existing = self.groups[id]
    if existing ~= nil and existing.farmId ~= groupFarmId then
        return nil, "crossFarmGroupIdForbidden"
    end
    local groupItems, countError = neutralItemCount(group)
    if groupItems == nil then
        return nil, countError
    end
    local existingItems = 0
    if existing ~= nil then
        existingItems, countError = neutralItemCount(existing)
        if existingItems == nil then
            return nil, countError
        end
    end
    local budgetDelta = groupItems - existingItems
    local budgeted, budgetReason = self:_preflightNeutralDelta(budgetDelta)
    if not budgeted then
        return nil, budgetReason
    end
    self.groups[id] = group
    self:_commitNeutralDelta(budgetDelta)
    return self:_copyForCaller(group)
end

function Ledger:_recordExclusionIds(record)
    local result = {}
    local recordExclusion = self.excludedTargets[record.id]
    if recordExclusion ~= nil then
        result[#result + 1] = recordExclusion
    end
    if record.sessionId ~= nil then
        local sessionExclusion = self.excludedTargets[record.sessionId]
        if sessionExclusion ~= nil then
            result[#result + 1] = sessionExclusion
        end
    end
    local _, identifiers = dependencies()
    table.sort(result, function(left, right)
        return identifiers.compare(left, right) < 0
    end)
    return result
end

function Ledger:_queryCycleIndexed(cycle, includeExcludedRows, recordOffset,
    recordLimit, includeLiveRows)
    local cycleId = cycle.id
    if self._recordIdsByCycle[cycleId] == nil
        or self._queryStateByCycle[cycleId] == nil then
        local rebuilt, reason = self:_rebuildCycleQueryIndexes(cycleId)
        if not rebuilt then return nil, reason end
    end
    local ids = includeExcludedRows and self._recordIdsByCycle[cycleId]
        or self._includedRecordIdsByCycle[cycleId]
    local total = #ids
    local last = total
    if recordLimit ~= nil then
        last = math.min(total, recordOffset + recordLimit)
    end
    local rows = {}
    for index = recordOffset + 1, last do
        local record = self.recordsById[ids[index]]
        if record == nil then return nil, "recordIndexCorrupt" end
        local exclusionIds = self:_recordExclusionIds(record)
        local excluded = #exclusionIds > 0
        local unallocated, markerError = unallocatedRecordMarker(record, self)
        if unallocated == nil then return nil, markerError end
        local row = self:_copyForCaller(record)
        if record.amount ~= nil then
            local adjusted, adjustError = self:_adjustedAmount(record.id)
            if adjusted == nil or adjusted < 0 then
                return nil, adjustError or "correctedTotalOutOfRange"
            end
            row.adjustedAmount = adjusted
        end
        row.excluded = excluded
        row.exclusionIds = exclusionIds
        row.includedInSummary = not excluded and not unallocated
        row.unallocated = unallocated
        rows[#rows + 1] = row
    end
    local corrections = {}
    for _, id in ipairs(self._correctionIdsByCycle[cycleId] or {}) do
        local correction = self.correctionsById[id]
        local target = correction and self.recordsById[correction.targetId]
        if correction == nil or target == nil or target.cycleId ~= cycleId then
            return nil, "correctionIndexCorrupt"
        end
        if target.amount ~= nil then
            local adjusted, adjustError = self:_adjustedAmount(target.id)
            if adjusted == nil or adjusted < 0 then
                return nil, adjustError or "correctedTotalOutOfRange"
            end
        end
        corrections[#corrections + 1] = self:_copyForCaller(correction)
    end
    local exclusions = {}
    for _, id in ipairs(self._exclusionIdsByCycle[cycleId] or {}) do
        local exclusion = self.exclusionsById[id]
        if exclusion == nil then return nil, "exclusionIndexCorrupt" end
        exclusions[#exclusions + 1] = self:_copyForCaller(exclusion)
    end
    local states = self.categoryStatesByCycle[cycleId]
    if states == nil then
        local reason
        states, reason = buildCategoryStates(self, cycleId)
        if states == nil then return nil, reason end
        self.categoryStatesByCycle[cycleId] = states
    end
    local categoryTotals, totalsError = categoryTotalsFromStoredStates(states)
    if categoryTotals == nil then return nil, totalsError end
    if includeLiveRows then
        categoryTotals, totalsError = categoryTotalsWithLive(
            self, cycleId, categoryTotals)
        if categoryTotals == nil then return nil, totalsError end
    end
    local queryState = self._queryStateByCycle[cycleId]
    local retention = cycle.retentionSummary
    local qualityCounts = self:_copyForCaller(queryState.qualityCounts)
    if retention ~= nil then
        for _, entry in ipairs(retention.entries or {}) do
            qualityCounts[entry.qualityClass] =
                (qualityCounts[entry.qualityClass] or 0)
                + (entry.sourceRecordCount or 0)
        end
    end
    return {
        cycle=self:_copyForCaller(cycle), records=rows,
        recordPage={offset=recordOffset, limit=recordLimit, total=total,
            nextOffset=recordLimit ~= nil and recordLimit > 0
                and recordOffset + #rows < total
                and recordOffset + #rows or nil},
        categoryTotals=categoryTotals,
        qualityCounts=qualityCounts,
        compactedRecordCount=retention and retention.prunedRecordCount or 0,
        directReplacementOverlap=(retention
            and retention.directReplacementOverlap == true)
            or queryState.directReplacementOverlap == true,
        corrections=corrections, exclusions=exclusions
    }
end

function Ledger:queryCycle(cycleId, options)
    if options ~= nil then
        local acceptedOptions = validateKnownFields(
            options,
            QUERY_OPTION_KEYS,
            "invalidOptions"
        )
        if acceptedOptions == nil then
            return nil, "invalidOptions"
        end
    end
    options = options or {}
    if options.includeExcluded ~= nil and type(options.includeExcluded) ~= "boolean" then
        return nil, "invalidOptions"
    end
    if options.includeLive ~= nil and type(options.includeLive) ~= "boolean" then
        return nil, "invalidOptions"
    end
    local includeLiveRows = options.includeLive ~= false
    local requestedOffset = options.recordOffset
    if requestedOffset == nil then
        requestedOffset = 0
    end
    local recordOffset, pagingError = validateInteger(
        requestedOffset,
        0,
        Constants.LIMITS.maxRecords
    )
    if recordOffset == nil then
        return nil, pagingError
    end
    local recordLimit = nil
    if options.recordLimit ~= nil then
        recordLimit, pagingError = validateInteger(
            options.recordLimit,
            0,
            Constants.LIMITS.maxRecords
        )
        if recordLimit == nil then
            return nil, pagingError
        end
    end
    local cycle = self.cyclesById[cycleId]
    if cycle == nil then
        return nil, "unknownCycle"
    end
    local retentionProjection = rawget(options, "_retentionPlan")
    local projectedSummary = nil
    local projectedRecordsToPrune = nil
    if retentionProjection ~= nil then
        if type(retentionProjection) ~= "table"
            or getmetatable(retentionProjection) ~= nil then
            return nil, "invalidRetentionPlan"
        end
        local projectedCycleId = rawget(retentionProjection, "cycleId")
        projectedRecordsToPrune = rawget(
            retentionProjection,
            "recordsToPrune"
        )
        local summarySource = rawget(retentionProjection, "summary")
        if projectedCycleId ~= cycleId
            or type(projectedRecordsToPrune) ~= "table"
            or getmetatable(projectedRecordsToPrune) ~= nil
            or type(summarySource) ~= "table"
            or getmetatable(summarySource) ~= nil then
            return nil, "invalidRetentionPlan"
        end
        projectedSummary = normalizeRetentionSummary(summarySource)
        if projectedSummary == nil then
            return nil, "invalidRetentionSummary"
        end
    end
    local includeExcludedRows = options.includeExcluded ~= false
    if retentionProjection == nil then
        return self:_queryCycleIndexed(cycle, includeExcludedRows,
            recordOffset, recordLimit, includeLiveRows)
    end
    local rows = {}
    local totalsByKey = {}
    local qualityCounts = {
        [Constants.QUALITY_CLASS.Complete] = 0,
        [Constants.QUALITY_CLASS.Partial] = 0,
        [Constants.QUALITY_CLASS.Unsupported] = 0
    }
    local exactSum, exactError = exactSumDependency()
    if exactSum == nil then
        return nil, exactError
    end
    local function categoryTotal(source)
        local aggregateKey = categoryAggregateKey(source)
        local total = totalsByKey[aggregateKey]
        if total == nil then
            local maximum = amountLimitForUnit(source.unit)
            if maximum == nil then
                return nil, "aggregateOutOfRange"
            end
            local accumulator = nil
            accumulator, exactError = exactSum.new(
                maximum,
                Constants.LIMITS.maxRecords
            )
            if accumulator == nil then
                return nil, exactError
            end
            total = {
                accountingClass = source.accountingClass,
                category = source.category,
                unit = source.unit,
                direction = source.direction,
                recordCount = 0,
                _exactSum = accumulator,
                _maximum = maximum
            }
            totalsByKey[aggregateKey] = total
        end
        return total
    end
    local function preflightCategoryCount(total, count)
        if total.recordCount + count > Constants.LIMITS.maxRecords then
            return nil, "aggregateCountOutOfRange"
        end
        return true
    end
    local function accumulateCategoryState(source, exactSource, count)
        local total, totalError = categoryTotal(source)
        if total == nil then
            return nil, totalError
        end
        local countAccepted, countError = preflightCategoryCount(total, count)
        if not countAccepted then
            return nil, countError
        end
        local merged, mergeError = exactSum.merge(total._exactSum, exactSource)
        if not merged then
            return nil, mergeError
        end
        total.recordCount = total.recordCount + count
        return true
    end
    local function accumulateRecordTerms(record)
        local total, totalError = categoryTotal(record)
        if total == nil then
            return nil, totalError
        end
        local countAccepted, countError = preflightCategoryCount(total, 1)
        if not countAccepted then
            return nil, countError
        end
        local added, addError = exactSum.add(total._exactSum, record.amount)
        if not added then
            return nil, addError
        end
        for _, correctionId in ipairs(self.correctionsByTarget[record.id] or {}) do
            local correction = self.correctionsById[correctionId]
            if correction == nil then
                return nil, "danglingCorrection"
            end
            added, addError = exactSum.add(total._exactSum, correction.delta)
            if not added then
                return nil, addError
            end
        end
        total.recordCount = total.recordCount + 1
        return true
    end
    local compactedRecordCount = 0
    local directReplacementOverlap = false
    local retentionSummary = projectedSummary or cycle.retentionSummary
    if retentionSummary ~= nil then
        compactedRecordCount = retentionSummary.prunedRecordCount
        directReplacementOverlap = retentionSummary.directReplacementOverlap
        for _, entry in ipairs(retentionSummary.entries) do
            qualityCounts[entry.qualityClass] = qualityCounts[entry.qualityClass]
                + entry.sourceRecordCount
            if entry.exactSum ~= nil then
                local accumulated, aggregateError = accumulateCategoryState(
                    entry,
                    entry.exactSum,
                    entry.sourceRecordCount
                )
                if not accumulated then
                    return nil, aggregateError
                end
            end
        end
    end
    local basisClasses = {}
    local eligibleRowCount = 0
    for _, recordId in ipairs(self.recordOrder) do
        local record = self.recordsById[recordId]
        if record.cycleId == cycleId
            and (retentionProjection == nil
                or projectedRecordsToPrune[recordId] ~= true) then
            local exclusionIds = self:_recordExclusionIds(record)
            local excluded = #exclusionIds > 0
            local unallocated, markerError = unallocatedRecordMarker(
                record, self)
            if unallocated == nil then
                return nil, markerError
            end
            local includedInSummary = not excluded and not unallocated
            local adjustedAmount = record.amount
            if record.amount ~= nil then
                if self.correctionsByTarget[recordId] ~= nil then
                    local adjustmentError = nil
                    adjustedAmount, adjustmentError = self:_adjustedAmount(recordId)
                    if adjustedAmount == nil or adjustedAmount < 0 then
                        return nil, adjustmentError or "correctedTotalOutOfRange"
                    end
                end
                if includedInSummary then
                    local accumulated, aggregateError = accumulateRecordTerms(record)
                    if not accumulated then
                        return nil, aggregateError
                    end
                end
            end
            if not excluded then
                qualityCounts[record.qualityClass] = qualityCounts[record.qualityClass] + 1
                if includedInSummary and record.basisId ~= nil
                    and (record.accountingClass == Constants.ACCOUNTING_CLASS.Direct
                        or record.accountingClass == Constants.ACCOUNTING_CLASS.Valued) then
                    local classes = basisClasses[record.basisId] or {}
                    classes[record.accountingClass] = true
                    basisClasses[record.basisId] = classes
                    if classes[Constants.ACCOUNTING_CLASS.Direct]
                        and classes[Constants.ACCOUNTING_CLASS.Valued] then
                        directReplacementOverlap = true
                    end
                end
            end
            if includeExcludedRows or not excluded then
                local rowIndex = eligibleRowCount
                eligibleRowCount = eligibleRowCount + 1
                if rowIndex >= recordOffset
                    and (recordLimit == nil or #rows < recordLimit) then
                    local row = self:_copyForCaller(record)
                    if record.amount ~= nil then
                        row.adjustedAmount = adjustedAmount
                    end
                    row.excluded = excluded
                    row.exclusionIds = exclusionIds
                    row.includedInSummary = includedInSummary
                    row.unallocated = unallocated
                    rows[#rows + 1] = row
                end
            end
        end
    end
    local categoryTotals = {}
    for _, total in pairs(totalsByKey) do
        local amount, aggregateError = exactSum.finish(
            total._exactSum,
            total._maximum
        )
        if amount == nil or amount < 0 then
            return nil, aggregateError or "aggregateOutOfRange"
        end
        total.amount = amount
        total._exactSum = nil
        total._maximum = nil
        categoryTotals[#categoryTotals + 1] = total
    end
    table.sort(categoryTotals, function(left, right)
        if left.accountingClass ~= right.accountingClass then
            return byteLess(left.accountingClass, right.accountingClass)
        end
        if left.category ~= right.category then
            return byteLess(left.category, right.category)
        end
        if left.unit ~= right.unit then
            return byteLess(left.unit, right.unit)
        end
        return byteLess(left.direction or "", right.direction or "")
    end)
    local corrections = {}
    for _, correctionId in ipairs(self.correctionOrder) do
        local correction = self.correctionsById[correctionId]
        local target = self.recordsById[correction.targetId]
        if target ~= nil and target.cycleId == cycleId then
            corrections[#corrections + 1] = self:_copyForCaller(correction)
        end
    end
    local exclusions = {}
    for _, exclusionId in ipairs(self.exclusionOrder) do
        local exclusion = self.exclusionsById[exclusionId]
        local target = self.recordsById[exclusion.targetId] or self.sessionsById[exclusion.targetId]
        if target ~= nil and target.cycleId == cycleId then
            exclusions[#exclusions + 1] = self:_copyForCaller(exclusion)
        end
    end
    return {
        cycle = self:_copyForCaller(cycle),
        records = rows,
        recordPage = {
            offset = recordOffset,
            limit = recordLimit,
            total = eligibleRowCount,
            nextOffset = recordLimit ~= nil
                and recordLimit > 0
                and recordOffset + #rows < eligibleRowCount
                and recordOffset + #rows
                or nil
        },
        categoryTotals = categoryTotals,
        qualityCounts = qualityCounts,
        compactedRecordCount = compactedRecordCount,
        directReplacementOverlap = directReplacementOverlap,
        corrections = corrections,
        exclusions = exclusions
    }
end

function Ledger:toNeutral()
    local document = {
        schemaVersion = self.schemaVersion,
        epoch = self.epoch,
        nextId = self.nextId,
        cycles = {},
        sessions = {},
        records = {},
        corrections = {},
        exclusions = {},
        aliases = shallowCopy(self.aliases),
        groups = {},
        settings = shallowCopy(self.settings)
    }
    for _, id in ipairs(self.cycleOrder) do
        document.cycles[#document.cycles + 1] = self.cyclesById[id]
    end
    for _, id in ipairs(self.sessionOrder) do
        local session = self.sessionsById[id]
        if session.state == Constants.SESSION_STATE.Open then
            return nil, "openSessionCheckpointRequired"
        end
        document.sessions[#document.sessions + 1] = session
    end
    for _, id in ipairs(self.recordOrder) do
        document.records[#document.records + 1] = self.recordsById[id]
    end
    for _, id in ipairs(self.correctionOrder) do
        document.corrections[#document.corrections + 1] = self.correctionsById[id]
    end
    for _, id in ipairs(self.exclusionOrder) do
        document.exclusions[#document.exclusions + 1] = self.exclusionsById[id]
    end
    for groupId, group in pairs(self.groups) do
        document.groups[groupId] = group
    end
    local itemCount, countError = neutralItemCount(document)
    if itemCount == nil then
        return nil, countError
    end
    if itemCount ~= self._neutralItems then
        return nil, "neutralBudgetInvariant"
    end
    if itemCount > self.neutralItemLimit then
        return nil, "ledgerNeutralBudgetExceeded"
    end
    return neutralCopy(document)
end

function Ledger.fromNeutral(document)
    if type(document) ~= "table" or getmetatable(document) ~= nil then
        return nil, "invalidLedgerDocument"
    end
    local documentKeys = {
        aliases = true,
        corrections = true,
        cycles = true,
        epoch = true,
        exclusions = true,
        groups = true,
        nextId = true,
        records = true,
        schemaVersion = true,
        sessions = true,
        settings = true
    }
    if validateKnownFields(document, documentKeys, "nonCanonicalLedgerDocument") == nil then
        return nil, "nonCanonicalLedgerDocument"
    end
    local source = shallowCopy(document)
    local schemaVersion, schemaError = validateInteger(source.schemaVersion, 1, Constants.SCHEMA_VERSION)
    if schemaVersion == nil or schemaVersion ~= Constants.SCHEMA_VERSION then
        return nil, schemaError or "unsupportedSchemaVersion"
    end
    local epoch, epochError = validateInteger(source.epoch, 1, Constants.LIMITS.maxIdentifier)
    if epoch == nil then
        return nil, epochError
    end
    local persistedNextId, nextIdError = validateInteger(
        source.nextId,
        1,
        Constants.LIMITS.maxRecords + 1
    )
    if persistedNextId == nil then
        return nil, nextIdError
    end
    local settingsKeys = {
        calendarYearSupported = true,
        retentionMode = true,
        retentionYears = true
    }
    if validateKnownFields(source.settings, settingsKeys, "invalidSettings") == nil then
        return nil, "invalidSettings"
    end
    if type(source.settings.calendarYearSupported) ~= "boolean" then
        return nil, "invalidCalendarYearSupport"
    end
    local retentionMode, retentionError = Core.Validation.enum(
        source.settings.retentionMode,
        Constants.RETENTION_MODE_SET
    )
    if retentionMode == nil then
        return nil, retentionError
    end
    local retentionYears = nil
    if retentionMode == Constants.RETENTION_MODE.GameYears then
        if source.settings.calendarYearSupported ~= true then
            return nil, "calendarYearRetentionUnsupported"
        end
        retentionYears, retentionError = validateInteger(
            source.settings.retentionYears,
            1,
            Constants.LIMITS.maxRetentionYears
        )
        if retentionYears == nil then
            return nil, retentionError
        end
    elseif source.settings.retentionYears ~= nil then
        return nil, "unexpectedRetentionYears"
    end
    local ledger, ledgerError = Ledger.new({
        epoch = epoch,
        calendarYearSupported = source.settings.calendarYearSupported
    })
    if ledger == nil then
        return nil, ledgerError
    end
    local configured, configureError = ledger:_setRetentionSettings(
        retentionMode,
        retentionYears
    )
    if configured == nil then
        return nil, configureError
    end
    ledger._loadingNeutral = true

    local diagnostics = {}
    local omittedDiagnostics = 0
    local function addDiagnostic(kind, entryId, index, reason)
        if #diagnostics < Constants.LIMITS.maxLoadDiagnostics - 1 then
            local diagnostic = {
                kind = kind,
                index = index,
                reason = reason or "invalidLedgerEntry"
            }
            if type(entryId) == "string" and #entryId <= Constants.LIMITS.idBytes then
                diagnostic.id = entryId
            end
            diagnostics[#diagnostics + 1] = diagnostic
        else
            omittedDiagnostics = omittedDiagnostics + 1
        end
    end

    local _, identifiers, dependencyError = dependencies()
    if dependencyError ~= nil then
        return nil, dependencyError
    end
    local entries = {}
    local numericIdCounts = {}
    local function addEntries(fieldName, expectedKind)
        local array, arrayError = Core.Validation.array(source[fieldName], Constants.LIMITS.maxRecords)
        if array == nil then
            return nil, arrayError
        end
        for index, value in ipairs(array) do
            if type(value) ~= "table" or getmetatable(value) ~= nil then
                addDiagnostic(expectedKind, nil, index, "invalidLedgerEntry")
            else
                local entryCopy = nil
                local entryCopyError = nil
                if expectedKind == "record" then
                    local _, metadataError = normalizeMetadata(rawget(value, "metadata"))
                    entryCopyError = metadataError
                end
                if entryCopyError == nil then
                    entryCopy, entryCopyError = neutralCopy(
                        value,
                        Constants.LIMITS.maxLedgerNeutralItems
                    )
                end
                if entryCopy == nil then
                    addDiagnostic(
                        expectedKind,
                        rawget(value, "id"),
                        index,
                        entryCopyError
                    )
                else
                local parsedKind, numericId, parseError = identifiers.parseRecordId(
                    entryCopy.id,
                    expectedKind
                )
                if parsedKind == nil or type(numericId) ~= "number" then
                    addDiagnostic(
                        expectedKind,
                        entryCopy.id,
                        index,
                        parseError or numericId or "invalidLedgerId"
                    )
                elseif numericId >= persistedNextId then
                    addDiagnostic(expectedKind, entryCopy.id, index, "ledgerIdBeyondNextId")
                else
                    numericIdCounts[numericId] = (numericIdCounts[numericId] or 0) + 1
                    entries[#entries + 1] = {
                        kind = expectedKind,
                        numericId = numericId,
                        sourceIndex = index,
                        value = entryCopy
                    }
                end
                end
            end
        end
        return true
    end
    local entryFields = {
        {"cycles", "cycle"},
        {"sessions", "session"},
        {"records", "record"},
        {"corrections", "correction"},
        {"exclusions", "exclusion"}
    }
    for _, descriptor in ipairs(entryFields) do
        local ok, addError = addEntries(descriptor[1], descriptor[2])
        if not ok then
            return nil, addError
        end
    end
    table.sort(entries, function(left, right)
        if left.numericId ~= right.numericId then
            return left.numericId < right.numericId
        end
        return byteLess(left.kind, right.kind)
    end)

    local storedCycles = {}
    local closedCycles = {}
    local function removeOrderValue(order, value)
        arrayRemoveValue(order, value)
    end
    local function dropCorrection(correctionId)
        local correction = ledger.correctionsById[correctionId]
        if correction == nil then
            return true
        end
        local count, countError = neutralItemCount(correction)
        if count == nil then
            return nil, countError
        end
        ledger.correctionsById[correctionId] = nil
        removeOrderValue(ledger.correctionOrder, correctionId)
        local byTarget = ledger.correctionsByTarget[correction.targetId]
        if byTarget ~= nil then
            removeOrderValue(byTarget, correctionId)
            if #byTarget == 0 then
                ledger.correctionsByTarget[correction.targetId] = nil
            end
        end
        ledger:_commitNeutralDelta(-count)
        return true
    end
    local function dropExclusion(exclusionId)
        local exclusion = ledger.exclusionsById[exclusionId]
        if exclusion == nil then
            return true
        end
        local count, countError = neutralItemCount(exclusion)
        if count == nil then
            return nil, countError
        end
        ledger.exclusionsById[exclusionId] = nil
        removeOrderValue(ledger.exclusionOrder, exclusionId)
        if ledger.excludedTargets[exclusion.targetId] == exclusionId then
            ledger.excludedTargets[exclusion.targetId] = nil
        end
        ledger:_commitNeutralDelta(-count)
        return true
    end
    local function dropRecord(recordId)
        local record = ledger.recordsById[recordId]
        if record == nil then
            return true
        end
        for index = #ledger.correctionOrder, 1, -1 do
            local correctionId = ledger.correctionOrder[index]
            if ledger.correctionsById[correctionId].targetId == recordId then
                local dropped, dropError = dropCorrection(correctionId)
                if not dropped then
                    return nil, dropError
                end
            end
        end
        for index = #ledger.exclusionOrder, 1, -1 do
            local exclusionId = ledger.exclusionOrder[index]
            if ledger.exclusionsById[exclusionId].targetId == recordId then
                local dropped, dropError = dropExclusion(exclusionId)
                if not dropped then
                    return nil, dropError
                end
            end
        end
        local count, countError = neutralItemCount(record)
        if count == nil then
            return nil, countError
        end
        ledger.observationIndex[record.observationId] = nil
        clearSegmentObservationOwnership(ledger, recordId)
        local transactionKey = directTransactionKey(record.directProvenance)
        if transactionKey ~= nil then
            ledger.directTransactionIndex[transactionKey] = nil
        end
        ledger.correctionsByTarget[recordId] = nil
        ledger.recordsById[recordId] = nil
        removeOrderValue(ledger.recordOrder, recordId)
        ledger:_commitNeutralDelta(-count)
        return true
    end
    local function dropSession(sessionId)
        local session = ledger.sessionsById[sessionId]
        if session == nil then
            return true
        end
        for index = #ledger.exclusionOrder, 1, -1 do
            local exclusionId = ledger.exclusionOrder[index]
            if ledger.exclusionsById[exclusionId].targetId == sessionId then
                local dropped, dropError = dropExclusion(exclusionId)
                if not dropped then
                    return nil, dropError
                end
            end
        end
        local count, countError = neutralItemCount(session)
        if count == nil then
            return nil, countError
        end
        local contextKey = ledger.contextKeyBySession[sessionId]
        if contextKey ~= nil and ledger.openSessionByContext[contextKey] == sessionId then
            ledger.openSessionByContext[contextKey] = nil
        end
        local rootVehicleId = ledger.rootKeyBySession[sessionId] or session.rootVehicleId
        if rootVehicleId ~= nil and ledger.openSessionByRoot[rootVehicleId] == sessionId then
            ledger.openSessionByRoot[rootVehicleId] = nil
        end
        ledger.contextKeyBySession[sessionId] = nil
        ledger.rootKeyBySession[sessionId] = nil
        ledger.lastEvidenceSequenceBySession[sessionId] = nil
        ledger.lastEvidencePayloadBySession[sessionId] = nil
        ledger.sessionsById[sessionId] = nil
        removeOrderValue(ledger.sessionOrder, sessionId)
        ledger:_commitNeutralDelta(-count)
        return true
    end
    local function dropCycle(cycleId)
        local cycle = ledger.cyclesById[cycleId]
        if cycle == nil then
            return true
        end
        for index = #ledger.recordOrder, 1, -1 do
            local recordId = ledger.recordOrder[index]
            if ledger.recordsById[recordId].cycleId == cycleId then
                local dropped, dropError = dropRecord(recordId)
                if not dropped then
                    return nil, dropError
                end
            end
        end
        for index = #ledger.sessionOrder, 1, -1 do
            local sessionId = ledger.sessionOrder[index]
            if ledger.sessionsById[sessionId].cycleId == cycleId then
                local dropped, dropError = dropSession(sessionId)
                if not dropped then
                    return nil, dropError
                end
            end
        end
        local count, countError = neutralItemCount(cycle)
        if count == nil then
            return nil, countError
        end
        if ledger.openCycleByLand[cycle.landKey] == cycleId then
            ledger.openCycleByLand[cycle.landKey] = nil
        end
        ledger.lastActivityTimeByCycle[cycleId] = nil
        ledger.categoryStatesByCycle[cycleId] = nil
        ledger.cyclesById[cycleId] = nil
        removeOrderValue(ledger.cycleOrder, cycleId)
        storedCycles[cycleId] = nil
        closedCycles[cycleId] = nil
        ledger.lastCycleByLand[cycle.landKey] = nil
        for index = #ledger.cycleOrder, 1, -1 do
            local candidate = ledger.cyclesById[ledger.cycleOrder[index]]
            if candidate.landKey == cycle.landKey then
                ledger.lastCycleByLand[cycle.landKey] = candidate.id
                break
            end
        end
        ledger:_commitNeutralDelta(-count)
        return true
    end
    local function closeStoredCycle(cycleId)
        if closedCycles[cycleId] then
            return true
        end
        local stored = storedCycles[cycleId]
        local cycle = ledger.cyclesById[cycleId]
        if stored == nil or cycle == nil then
            return nil, "unknownStoredCycle"
        end
        if stored.state == Constants.CYCLE_STATE.Closed
            or stored.state == Constants.CYCLE_STATE.Archived then
            local closed, closeError = ledger:closeCycle({
                cycleId = cycleId,
                missionTime = stored.endMissionTime,
                period = stored.endPeriod,
                year = stored.endYear,
                reason = stored.closeReason
            })
            if closed == nil then
                return nil, closeError
            end
        elseif stored.state ~= Constants.CYCLE_STATE.Open then
            return nil, "invalidCycleState"
        end
        closedCycles[cycleId] = true
        return true
    end
    for _, entry in ipairs(entries) do
        local value = entry.value
        if numericIdCounts[entry.numericId] > 1 then
            addDiagnostic(entry.kind, value.id, entry.sourceIndex, "duplicateLedgerId")
        else
            ledger.nextId = entry.numericId
            local replayed = nil
            local replayError = nil
            if entry.kind == "cycle" then
                local previousCycleId = type(value.landKey) == "string"
                    and ledger.openCycleByLand[value.landKey]
                    or nil
                if previousCycleId ~= nil then
                    local finalized, finalizeError = closeStoredCycle(previousCycleId)
                    if not finalized then
                        addDiagnostic(
                            "cycle",
                            previousCycleId,
                            entry.sourceIndex,
                            finalizeError
                        )
                        local dropped, dropError = dropCycle(previousCycleId)
                        if not dropped then
                            return nil, dropError
                        end
                    end
                end
                replayed, replayError = ledger:openCycle({
                    landKey = value.landKey,
                    fruitType = value.fruitType,
                    fruitTypeId = value.fruitTypeId,
                    fillTypeId = value.fillTypeId,
                    period = value.startPeriod,
                    missionTime = value.startMissionTime,
                    year = value.startYear,
                    cycleAreaHa = value.cycleAreaHa,
                    qualityClass = value.qualityClass,
                    reasons = value.reasons
                })
                if replayed ~= nil then
                    storedCycles[value.id] = value
                end
            elseif entry.kind == "session" then
                if value.state ~= Constants.SESSION_STATE.Closed then
                    replayError = "persistedOpenSession"
                else
                    local sessionCommand = {
                        evidence = true,
                        cycleId = value.cycleId,
                        landKey = value.landKey,
                        rootVehicleId = value.rootVehicleId,
                        operationType = value.operationType,
                        fillType = value.fillType,
                        carrierKind = value.carrierKind,
                        operatorKind = value.operatorKind,
                        operatorId = value.operatorId,
                        operatorQuality = value.operatorQuality,
                        implementIds = value.implementIds,
                        missionTime = value.firstEvidenceTime,
                        reasons = value.reasons
                    }
                    replayed, replayError = ledger:startSession(sessionCommand)
                    if replayed ~= nil
                        and value.carrierKind
                            == ZERO_CHANGED_APPLICATION_CARRIER_KIND
                        and value.activeMs == 0
                        and value.lastEvidenceTime
                            ~= value.firstEvidenceTime then
                        replayed, replayError = replayCarrierTiming(
                            ledger, replayed.id, value.lastEvidenceTime)
                    end
                end
                if replayed ~= nil and replayed.id == value.id then
                    if value.carrierKind
                        == ZERO_CHANGED_APPLICATION_CARRIER_KIND then
                        if value.activeMs ~= 0 then
                            replayed = nil
                            replayError = "invalidZeroChangedApplicationCarrier"
                        end
                    else
                        local evidence, evidenceError = ledger:recordEvidence({
                            sessionId = replayed.id,
                            serverSequence = 0,
                            activeMs = value.activeMs,
                            missionTime = value.lastEvidenceTime
                        })
                        if evidence == nil then
                            replayError = evidenceError
                            replayed = nil
                        end
                    end
                    if replayed ~= nil then
                        replayed, replayError = ledger:closeSession({
                            sessionId = replayed.id,
                            reason = value.closeReason,
                            endMissionTime = value.endMissionTime
                        })
                    end
                end
            elseif entry.kind == "record" then
                replayed, replayError = ledger:acceptRecord({
                    cycleId = value.cycleId,
                    sessionId = value.sessionId,
                    recordType = value.recordType,
                    category = value.category,
                    accountingClass = value.accountingClass,
                    qualityClass = value.qualityClass,
                    amount = value.amount,
                    unit = value.unit,
                    direction = value.direction,
                    missionTime = value.missionTime,
                    observationId = value.observationId,
                    basisId = value.basisId,
                    directProvenance = value.directProvenance,
                    reasons = value.reasons,
                    metadata = value.metadata,
                    references = value.references
                })
            elseif entry.kind == "correction" then
                replayed, replayError = ledger:appendCorrection({
                    targetId = value.targetId,
                    delta = value.delta,
                    authorFarmId = value.authorFarmId,
                    authorUserId = value.authorUserId,
                    missionTime = value.missionTime,
                    reason = value.reason
                })
            elseif entry.kind == "exclusion" then
                replayed, replayError = ledger:appendExclusion({
                    targetId = value.targetId,
                    targetKind = value.targetKind,
                    authorFarmId = value.authorFarmId,
                    authorUserId = value.authorUserId,
                    missionTime = value.missionTime,
                    reason = value.reason
                })
            end
            local mismatch = replayed ~= nil
                and (replayed.id ~= value.id
                    or (entry.kind ~= "cycle" and not neutralEqual(replayed, value)))
            if replayed == nil or mismatch then
                if entry.kind == "record" and ledger.recordsById[value.id] ~= nil then
                    local dropped, dropError = dropRecord(value.id)
                    if not dropped then
                        return nil, dropError
                    end
                elseif entry.kind == "session" and ledger.sessionsById[value.id] ~= nil then
                    local dropped, dropError = dropSession(value.id)
                    if not dropped then
                        return nil, dropError
                    end
                elseif entry.kind == "correction" and ledger.correctionsById[value.id] ~= nil then
                    local dropped, dropError = dropCorrection(value.id)
                    if not dropped then
                        return nil, dropError
                    end
                elseif entry.kind == "exclusion" and ledger.exclusionsById[value.id] ~= nil then
                    local dropped, dropError = dropExclusion(value.id)
                    if not dropped then
                        return nil, dropError
                    end
                elseif entry.kind == "cycle" and ledger.cyclesById[value.id] ~= nil then
                    local dropped, dropError = dropCycle(value.id)
                    if not dropped then
                        return nil, dropError
                    end
                end
                addDiagnostic(
                    entry.kind,
                    value.id,
                    entry.sourceIndex,
                    mismatch and "ledgerEntryMismatch" or replayError
                )
            end
        end
    end

    local cycleIds = {}
    for _, cycleId in ipairs(ledger.cycleOrder) do
        cycleIds[#cycleIds + 1] = cycleId
    end
    for _, cycleId in ipairs(cycleIds) do
        local finalized, finalizeError = closeStoredCycle(cycleId)
        if not finalized then
            addDiagnostic("cycle", cycleId, 0, finalizeError)
            local dropped, dropError = dropCycle(cycleId)
            if not dropped then
                return nil, dropError
            end
        else
            local stored = storedCycles[cycleId]
            local cycle = ledger.cyclesById[cycleId]
            if stored.state == Constants.CYCLE_STATE.Archived then
                local summary, summaryError = normalizeRetentionSummary(
                    stored.retentionSummary
                )
                local residualValid, residualError = ledger:_validateArchivedResidual(cycle)
                local proposed = shallowCopy(cycle)
                proposed.state = Constants.CYCLE_STATE.Archived
                proposed.archiveReason = "retentionCompaction"
                proposed.retentionSummary = summary
                if summary == nil
                    or stored.archiveReason ~= "retentionCompaction"
                    or not residualValid
                    or not neutralEqual(proposed, stored) then
                    addDiagnostic(
                        "cycle",
                        cycleId,
                        0,
                        summaryError or residualError or "ledgerEntryMismatch"
                    )
                    local dropped, dropError = dropCycle(cycleId)
                    if not dropped then
                        return nil, dropError
                    end
                else
                    local budgetDelta, budgetError = ledger:_replacementNeutralDelta(
                        cycle,
                        proposed
                    )
                    if budgetDelta == nil then
                        return nil, budgetError
                    end
                    local budgeted, budgetReason = ledger:_preflightNeutralDelta(budgetDelta)
                    if not budgeted then
                        addDiagnostic("cycle", cycleId, 0, budgetReason)
                        local dropped, dropError = dropCycle(cycleId)
                        if not dropped then
                            return nil, dropError
                        end
                    else
                        cycle.state = proposed.state
                        cycle.archiveReason = proposed.archiveReason
                        cycle.retentionSummary = summary
                        ledger:_commitNeutralDelta(budgetDelta)
                    end
                end
            elseif not neutralEqual(cycle, stored) then
                addDiagnostic("cycle", cycleId, 0, "ledgerEntryMismatch")
                local dropped, dropError = dropCycle(cycleId)
                if not dropped then
                    return nil, dropError
                end
            end
        end
    end

    for _, cycleId in ipairs(cycleIds) do
        if ledger.cyclesById[cycleId] ~= nil then
            local categoryStates, categoryError = buildCategoryStates(
                ledger,
                cycleId
            )
            if categoryStates == nil then
                addDiagnostic("cycle", cycleId, 0, categoryError)
                local dropped, dropError = dropCycle(cycleId)
                if not dropped then
                    return nil, dropError
                end
            else
                ledger.categoryStatesByCycle[cycleId] = categoryStates
            end
        end
    end

    if type(source.aliases) ~= "table" or getmetatable(source.aliases) ~= nil then
        addDiagnostic("aliases", nil, 0, "invalidAliases")
    else
        local aliasKeys = {}
        local aliasesError = nil
        for landKey in next, source.aliases do
            if type(landKey) ~= "string" or #landKey > Constants.LIMITS.idBytes then
                aliasesError = "invalidAliases"
                break
            elseif #aliasKeys >= ledger.neutralItemLimit then
                aliasesError = "ledgerNeutralBudgetExceeded"
                break
            end
            aliasKeys[#aliasKeys + 1] = landKey
        end
        if aliasesError ~= nil then
            addDiagnostic("aliases", nil, 0, aliasesError)
        else
            table.sort(aliasKeys, function(left, right)
                return identifiers.compare(left, right) < 0
            end)
            for index, landKey in ipairs(aliasKeys) do
                local storedAlias, aliasError = ledger:setAlias(
                    landKey,
                    source.aliases[landKey]
                )
                if storedAlias == nil then
                    addDiagnostic("alias", landKey, index, aliasError)
                end
            end
        end
    end
    if type(source.groups) ~= "table" or getmetatable(source.groups) ~= nil then
        addDiagnostic("groups", nil, 0, "invalidGroups")
    else
        local groupIds = {}
        local groupsError = nil
        for groupId in next, source.groups do
            if type(groupId) ~= "string" or #groupId > Constants.LIMITS.idBytes then
                groupsError = "invalidGroups"
                break
            elseif #groupIds >= ledger.neutralItemLimit then
                groupsError = "ledgerNeutralBudgetExceeded"
                break
            end
            groupIds[#groupIds + 1] = groupId
        end
        if groupsError ~= nil then
            addDiagnostic("groups", nil, 0, groupsError)
        else
            table.sort(groupIds, function(left, right)
                return identifiers.compare(left, right) < 0
            end)
            for index, groupId in ipairs(groupIds) do
                local group = source.groups[groupId]
                local storedGroup = nil
                local groupError = "invalidGroup"
                if type(group) == "table" and getmetatable(group) == nil then
                    storedGroup, groupError = ledger:setGroup(groupId, group.landKeys)
                    if storedGroup ~= nil and not neutralEqual(storedGroup, group) then
                        ledger.groups[groupId] = nil
                        local groupItems = neutralItemCount(storedGroup)
                        ledger:_commitNeutralDelta(-groupItems)
                        storedGroup = nil
                        groupError = "groupMismatch"
                    end
                end
                if storedGroup == nil then
                    addDiagnostic("group", groupId, index, groupError)
                end
            end
        end
    end
    ledger.nextId = persistedNextId
    ledger._loadingNeutral = false
    ledger.lastEvidenceSequenceByRoot = {}
    ledger.lastEvidencePayloadByRoot = {}
    if omittedDiagnostics > 0 then
        diagnostics[#diagnostics + 1] = {
            kind = "load",
            omittedCount = omittedDiagnostics,
            reason = "diagnosticsTruncated"
        }
    end
    ledger.loadDiagnostics = diagnostics
    local indexesRebuilt, indexReason = ledger:_rebuildAllQueryIndexes()
    if not indexesRebuilt then return nil, indexReason end
    ledger._reportRevision = 1
    for _, cycleId in ipairs(ledger.cycleOrder) do
        ledger._cycleRevisionById[cycleId] = 1
    end
    local rebuilt, rebuiltError = ledger:toNeutral()
    if rebuilt == nil then
        return nil, rebuiltError
    end
    if #diagnostics == 0 and not neutralEqual(rebuilt, source) then
        return nil, "nonCanonicalLedgerDocument"
    end
    local usedEpochs = {}
    local usedEpochCount = 0
    for _, recordId in ipairs(ledger.recordOrder) do
        local parts = identifiers.parseObservationId(
            ledger.recordsById[recordId].observationId
        )
        if parts ~= nil and not usedEpochs[parts.epoch] then
            usedEpochs[parts.epoch] = true
            usedEpochCount = usedEpochCount + 1
        end
    end
    local rotatedEpoch = epoch
    for _ = 1, usedEpochCount + 1 do
        if rotatedEpoch >= Constants.LIMITS.maxIdentifier then
            rotatedEpoch = 1
        else
            rotatedEpoch = rotatedEpoch + 1
        end
        if not usedEpochs[rotatedEpoch] then
            break
        end
    end
    if rotatedEpoch == epoch or usedEpochs[rotatedEpoch] then
        return nil, "observationEpochExhausted"
    end
    ledger.epoch = rotatedEpoch
    return ledger
end

function Ledger:deleteCycleHistory(command)
    if type(command) ~= "table" or command.confirmed ~= true then
        return nil, "explicitConfirmationRequired"
    end
    local cycle = self.cyclesById[command.cycleId]
    if cycle == nil then
        return nil, "unknownCycle"
    end
    local farmId, farmError = validateInteger(command.farmId, 1, Constants.LIMITS.maxIdentifier)
    if farmId == nil then
        return nil, farmError
    end
    if cycle.farmId ~= farmId then
        return nil, "farmAuthorityMismatch"
    end
    if cycle.state == Constants.CYCLE_STATE.Open then
        return nil, "openCycleDeletionForbidden"
    end
    local removedItems, countError = neutralItemCount(cycle)
    if removedItems == nil then
        return nil, countError
    end
    for _, sessionId in ipairs(self.sessionOrder) do
        local session = self.sessionsById[sessionId]
        if session.cycleId == cycle.id then
            local itemCount = nil
            itemCount, countError = neutralItemCount(session)
            if itemCount == nil then
                return nil, countError
            end
            removedItems = removedItems + itemCount
        end
    end
    local recordsMarkedForDeletion = {}
    for _, recordId in ipairs(self.recordOrder) do
        local record = self.recordsById[recordId]
        if record.cycleId == cycle.id then
            recordsMarkedForDeletion[recordId] = true
            local itemCount = nil
            itemCount, countError = neutralItemCount(record)
            if itemCount == nil then
                return nil, countError
            end
            removedItems = removedItems + itemCount
        end
    end
    for _, correctionId in ipairs(self.correctionOrder) do
        local correction = self.correctionsById[correctionId]
        if recordsMarkedForDeletion[correction.targetId] then
            local itemCount = nil
            itemCount, countError = neutralItemCount(correction)
            if itemCount == nil then
                return nil, countError
            end
            removedItems = removedItems + itemCount
        end
    end
    for _, exclusionId in ipairs(self.exclusionOrder) do
        local exclusion = self.exclusionsById[exclusionId]
        local target = self.recordsById[exclusion.targetId]
            or self.sessionsById[exclusion.targetId]
        if target ~= nil and target.cycleId == cycle.id then
            local itemCount = nil
            itemCount, countError = neutralItemCount(exclusion)
            if itemCount == nil then
                return nil, countError
            end
            removedItems = removedItems + itemCount
        end
    end
    local budgeted, budgetReason = self:_preflightNeutralDelta(-removedItems)
    if not budgeted then
        return nil, budgetReason
    end
    local deletedRecords = {}
    local deletedSessions = {}
    for index = #self.sessionOrder, 1, -1 do
        local id = self.sessionOrder[index]
        local session = self.sessionsById[id]
        if session.cycleId == cycle.id then
            deletedSessions[id] = true
            local contextKey = self.contextKeyBySession[id]
            if contextKey ~= nil then
                self.openSessionByContext[contextKey] = nil
            end
            self.contextKeyBySession[id] = nil
            local rootVehicleId = self.rootKeyBySession[id] or session.rootVehicleId
            if rootVehicleId ~= nil and self.openSessionByRoot[rootVehicleId] == id then
                self.openSessionByRoot[rootVehicleId] = nil
            end
            self.rootKeyBySession[id] = nil
            self.lastEvidenceSequenceBySession[id] = nil
            self.lastEvidencePayloadBySession[id] = nil
            self.sessionsById[id] = nil
            table.remove(self.sessionOrder, index)
        end
    end
    for index = #self.recordOrder, 1, -1 do
        local recordId = self.recordOrder[index]
        if self.recordsById[recordId].cycleId == cycle.id then
            local transactionKey = directTransactionKey(
                self.recordsById[recordId].directProvenance
            )
            if transactionKey ~= nil then
                self.directTransactionIndex[transactionKey] = nil
            end
            deletedRecords[recordId] = true
            self.observationIndex[self.recordsById[recordId].observationId] = nil
            clearSegmentObservationOwnership(self, recordId)
            self.recordsById[recordId] = nil
            table.remove(self.recordOrder, index)
        end
    end
    local deletedCorrectionCount = 0
    for index = #self.correctionOrder, 1, -1 do
        local id = self.correctionOrder[index]
        local targetId = self.correctionsById[id].targetId
        if deletedRecords[targetId] then
            deletedCorrectionCount = deletedCorrectionCount + 1
            self.correctionsById[id] = nil
            table.remove(self.correctionOrder, index)
        end
    end
    for recordId in pairs(deletedRecords) do
        self.correctionsByTarget[recordId] = nil
    end
    local deletedExclusionCount = 0
    for index = #self.exclusionOrder, 1, -1 do
        local id = self.exclusionOrder[index]
        local targetId = self.exclusionsById[id].targetId
        if deletedRecords[targetId] or deletedSessions[targetId] then
            deletedExclusionCount = deletedExclusionCount + 1
            self.excludedTargets[targetId] = nil
            self.exclusionsById[id] = nil
            table.remove(self.exclusionOrder, index)
        end
    end
    if self.openCycleByLand[cycle.landKey] == cycle.id then
        self.openCycleByLand[cycle.landKey] = nil
    end
    if self.lastCycleByLand[cycle.landKey] == cycle.id then
        self.lastCycleByLand[cycle.landKey] = nil
        for index = #self.cycleOrder, 1, -1 do
            local candidateId = self.cycleOrder[index]
            local candidate = self.cyclesById[candidateId]
            if candidate ~= nil and candidate.id ~= cycle.id
                and candidate.landKey == cycle.landKey then
                self.lastCycleByLand[cycle.landKey] = candidate.id
                break
            end
        end
    end
    self.lastActivityTimeByCycle[cycle.id] = nil
    self.categoryStatesByCycle[cycle.id] = nil
    self._recordIdsByCycle[cycle.id] = nil
    self._includedRecordIdsByCycle[cycle.id] = nil
    self._cycleBoundaryEvidenceByCycle[cycle.id] = nil
    self._correctionIdsByCycle[cycle.id] = nil
    self._exclusionIdsByCycle[cycle.id] = nil
    self._queryStateByCycle[cycle.id] = nil
    self._cycleRevisionById[cycle.id] = nil
    self.cyclesById[cycle.id] = nil
    arrayRemoveValue(self.cycleOrder, cycle.id)
    self:_commitNeutralDelta(-removedItems)
    self:_touchReport(nil)
    return {
        cycleId = command.cycleId,
        deletedRecordCount = (function()
            local count = 0
            for _ in pairs(deletedRecords) do
                count = count + 1
            end
            return count
        end)(),
        deletedSessionCount = (function()
            local count = 0
            for _ in pairs(deletedSessions) do
                count = count + 1
            end
            return count
        end)(),
        deletedCorrectionCount = deletedCorrectionCount,
        deletedExclusionCount = deletedExclusionCount
    }
end

FieldProfitabilityLedger.Core.Ledger = Ledger

return Ledger
