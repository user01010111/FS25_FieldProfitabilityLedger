FieldProfitabilityLedger = FieldProfitabilityLedger or {}
FieldProfitabilityLedger.Core = FieldProfitabilityLedger.Core or {}

local Core = FieldProfitabilityLedger.Core
local Constants = Core.Constants

local Retention = {}

local function dependencies()
    local validation = Core.Validation
    local identifiers = Core.Identifiers
    if type(validation) ~= "table" then
        return nil, nil, "validationUnavailable"
    end
    if type(identifiers) ~= "table" or type(identifiers.compare) ~= "function" then
        return nil, nil, "identifiersUnavailable"
    end
    return validation, identifiers
end

local function exactSumDependency()
    local exactSum = Core.ExactSum
    if type(exactSum) ~= "table"
        or type(exactSum.new) ~= "function"
        or type(exactSum.add) ~= "function"
        or type(exactSum.finish) ~= "function"
        or type(exactSum.toNeutral) ~= "function" then
        return nil, "exactSumUnavailable"
    end
    return exactSum
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

local function lengthPrefixed(parts)
    local result = {}
    for index, part in ipairs(parts) do
        part = part or ""
        result[index] = string.format("%d:%s", string.len(part), part)
    end
    return table.concat(result, "|")
end

local function validLedger(ledger)
    return type(ledger) == "table"
        and type(ledger.cyclesById) == "table"
        and type(ledger.cycleOrder) == "table"
        and type(ledger.recordsById) == "table"
        and type(ledger.recordOrder) == "table"
        and type(ledger.sessionsById) == "table"
        and type(ledger.sessionOrder) == "table"
        and type(ledger.settings) == "table"
        and type(ledger._setRetentionSettings) == "function"
        and type(ledger._retentionPlanPreservesQuery) == "function"
        and type(ledger._retentionPlanNeutralDelta) == "function"
        and type(ledger._preflightNeutralDelta) == "function"
        and type(ledger._applyRetentionPlan) == "function"
        and type(ledger.validateRetentionSummary) == "function"
end

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

local CONFIG_KEYS = {
    keepYears = true,
    mode = true
}

local function copyForCaller(value)
    local validation, _, dependencyError = dependencies()
    if dependencyError ~= nil then
        return nil, dependencyError
    end
    return validation.copy(value, {
        maxDepth = Constants.LIMITS.maxNeutralDepth,
        maxItems = Constants.LIMITS.maxNeutralItems,
        maxStringBytes = Constants.LIMITS.textBytes,
        maxNumber = Constants.LIMITS.maxIdentifier
    })
end

function Retention.configure(ledger, command)
    if not validLedger(ledger) then
        return nil, "invalidLedger"
    end
    local validation, _, dependencyError = dependencies()
    if dependencyError ~= nil then
        return nil, dependencyError
    end
    local accepted, commandError = validateKnownFields(command, CONFIG_KEYS, "invalidRetentionConfig")
    if accepted == nil then
        return nil, commandError
    end
    local mode, modeError = validation.enum(accepted.mode, Constants.RETENTION_MODE_SET)
    if mode == nil then
        return nil, modeError
    end
    local keepYears = nil
    if mode == Constants.RETENTION_MODE.GameYears then
        if ledger.settings.calendarYearSupported ~= true then
            return nil, "calendarYearRetentionUnsupported"
        end
        keepYears, modeError = validation.integer(
            accepted.keepYears,
            1,
            Constants.LIMITS.maxRetentionYears
        )
        if keepYears == nil then
            return nil, modeError
        end
    elseif accepted.keepYears ~= nil then
        return nil, "unexpectedRetentionYears"
    end
    return ledger:_setRetentionSettings(mode, keepYears)
end

local function validateCurrentYear(ledger, currentYear)
    local validation, _, dependencyError = dependencies()
    if dependencyError ~= nil then
        return nil, dependencyError
    end
    if ledger.settings.retentionMode == Constants.RETENTION_MODE.All then
        if currentYear ~= nil then
            return nil, "yearNotUsedInAllMode"
        end
        return nil, nil
    end
    if ledger.settings.retentionMode ~= Constants.RETENTION_MODE.GameYears
        or ledger.settings.calendarYearSupported ~= true then
        return nil, "calendarYearRetentionUnsupported"
    end
    return validation.integer(currentYear, 0, Constants.LIMITS.maxYear)
end

function Retention.plan(ledger, currentYear)
    if not validLedger(ledger) then
        return nil, "invalidLedger"
    end
    local acceptedYear, yearError = validateCurrentYear(ledger, currentYear)
    if yearError ~= nil then
        return nil, yearError
    end
    if ledger.settings.retentionMode == Constants.RETENTION_MODE.All then
        return {}
    end
    local cutoff = acceptedYear - ledger.settings.retentionYears
    local result = {}
    for _, cycleId in ipairs(ledger.cycleOrder) do
        local cycle = ledger.cyclesById[cycleId]
        if cycle.state == Constants.CYCLE_STATE.Closed
            and cycle.endYear ~= nil
            and cycle.endYear <= cutoff then
            result[#result + 1] = cycleId
        end
    end
    return result
end

local function hasReason(record, expected)
    for _, reason in ipairs(record.reasons or {}) do
        if reason == expected then
            return true
        end
    end
    return false
end

local APPLICATION_CATEGORIES = {
    seed=true, fertilizer=true, lime=true, herbicide=true,
    manure=true, slurry=true, digestate=true
}

local APPLICATION_OPERATIONS = {
    seed="seedingPlanting", fertilizer="fertilizer", lime="lime",
    herbicide="herbicide", manure="manure", slurry="slurry",
    digestate="digestate"
}

local function isUnallocated(ledger, record)
    if type(record) ~= "table" then
        return nil, "invalidRecord"
    end
    local metadata = record.metadata
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
    local mixed = record.category == "mixedBoundaryTick"
        or hasReason(record, "mixedBoundaryTick")
        or hasReason(record, "boundaryUnresolved")
        or metadata.mixedBoundary == true
        or metadata.unresolvedMixedBoundary == true
    local kind = metadata.unallocatedKind
    if kind ~= nil and kind ~= "zeroChangedApplication" then
        return nil, "invalidUnallocatedKind"
    end
    if kind == "zeroChangedApplication" then
        if mixed or metadata.candidateLandKeys ~= nil then
            return nil, "unallocatedMarkerCollision"
        end
        local amount = record.amount
        local session = record.sessionId ~= nil
            and ledger.sessionsById[record.sessionId] or nil
        local expectedOperation = APPLICATION_OPERATIONS[record.category]
        if record.recordType ~= Constants.RECORD_TYPE.Input
            or record.accountingClass ~= Constants.ACCOUNTING_CLASS.Observed
            or APPLICATION_CATEGORIES[record.category] ~= true
            or record.qualityClass ~= Constants.QUALITY_CLASS.Partial
            or record.unit ~= Constants.UNIT.Litres
            or type(amount) ~= "number" or amount ~= amount
            or amount == math.huge or amount == -math.huge or amount <= 0
            or not hasReason(record, "zeroChangedArea")
            or (metadata.attributionKind ~= "baseField"
                and metadata.attributionKind ~= "parcel")
            or metadata.areaEvidence ~= "zeroChanged"
            or metadata.carrierLandKey ~= record.landKey
            or session == nil or session.cycleId ~= record.cycleId
            or session.landKey ~= record.landKey
            or session.carrierKind ~= "zeroChangedApplication"
            or session.operationType ~= expectedOperation
            or session.activeMs ~= 0
            or type(record.references) ~= "table"
            or #record.references ~= 0 then
            return nil, "invalidZeroChangedApplication"
        end
        return true
    end
    if mixed then return true end
    if rawget(metadata, "unallocated") ~= nil
        or rawget(metadata, "carrierOnly") ~= nil then
        return nil, "reservedUnallocatedFlag"
    end
    return false
end

local function entryKey(record)
    return lengthPrefixed({
        record.recordType,
        record.accountingClass,
        record.category,
        record.qualityClass,
        record.unit,
        record.direction,
        lengthPrefixed(record.reasons)
    })
end

local function recordExcluded(ledger, record)
    return ledger.excludedTargets[record.id] ~= nil
        or (record.sessionId ~= nil and ledger.excludedTargets[record.sessionId] ~= nil)
end

local function buildCyclePlan(ledger, cycle, currentYear)
    local protectedRecords = {}
    local protectedSessions = {}
    local unallocatedRecords = {}

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
            local unallocated, markerError = isUnallocated(ledger, record)
            if unallocated == nil then
                return nil, markerError
            end
            if unallocated
                or record.recordType == Constants.RECORD_TYPE.Valuation
                or record.accountingClass == Constants.ACCOUNTING_CLASS.Direct
                or record.directProvenance ~= nil then
                protectedRecords[recordId] = true
            end
            if unallocated then
                unallocatedRecords[recordId] = true
            end
            if protectedSessions[record.sessionId] then
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
                    if ledger.recordsById[reference] ~= nil and not protectedRecords[reference] then
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

    local exactSum, exactError = exactSumDependency()
    if exactSum == nil then
        return nil, exactError
    end
    local basisClasses = {}
    local groups = {}
    local recordsToPrune = {}
    for _, recordId in ipairs(ledger.recordOrder) do
        local record = ledger.recordsById[recordId]
        if record.cycleId == cycle.id then
            if not recordExcluded(ledger, record)
                and not unallocatedRecords[recordId]
                and record.basisId ~= nil
                and (record.accountingClass == Constants.ACCOUNTING_CLASS.Direct
                    or record.accountingClass == Constants.ACCOUNTING_CLASS.Valued) then
                local classes = basisClasses[record.basisId] or {}
                classes[record.accountingClass] = true
                basisClasses[record.basisId] = classes
            end
            if not protectedRecords[recordId] then
                recordsToPrune[recordId] = true
                local key = entryKey(record)
                local group = groups[key]
                if group == nil then
                    local accumulator = nil
                    local maximum = nil
                    if record.amount ~= nil then
                        maximum = Constants.UNIT_LIMIT[record.unit]
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
        end
    end

    local entries = {}
    local keys = {}
    for key in pairs(groups) do
        keys[#keys + 1] = key
    end
    table.sort(keys, byteLess)
    if #keys > Constants.LIMITS.maxComponents then
        return nil, "tooManyRetentionComponents"
    end
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

    local sessionsToPrune = {}
    local prunedSessionCount = 0
    for _, sessionId in ipairs(ledger.sessionOrder) do
        local session = ledger.sessionsById[sessionId]
        if session.cycleId == cycle.id and not protectedSessions[sessionId] then
            if session.state ~= Constants.SESSION_STATE.Closed then
                return nil, "openSessionRetentionForbidden"
            end
            sessionsToPrune[sessionId] = true
            prunedSessionCount = prunedSessionCount + 1
        end
    end

    local prunedRecordCount = 0
    for _ in pairs(recordsToPrune) do
        prunedRecordCount = prunedRecordCount + 1
    end
    local overlap = false
    for _, classes in pairs(basisClasses) do
        if classes[Constants.ACCOUNTING_CLASS.Direct]
            and classes[Constants.ACCOUNTING_CLASS.Valued] then
            overlap = true
            break
        end
    end
    local summary = {
        compactedAtYear = currentYear,
        directReplacementOverlap = overlap,
        entries = entries,
        prunedRecordCount = prunedRecordCount,
        prunedSessionCount = prunedSessionCount
    }
    local normalized, summaryError = ledger:validateRetentionSummary(summary)
    if normalized == nil then
        return nil, summaryError
    end
    return {
        cycleId = cycle.id,
        recordsToPrune = recordsToPrune,
        sessionsToPrune = sessionsToPrune,
        summary = normalized
    }
end

local function applyCyclePlan(ledger, plan)
    return ledger:_applyRetentionPlan(plan)
end

function Retention.compact(ledger, currentYear)
    if not validLedger(ledger) then
        return nil, "invalidLedger"
    end
    local cycleIds, planError = Retention.plan(ledger, currentYear)
    if cycleIds == nil then
        return nil, planError
    end
    if #cycleIds == 0 then
        return {}
    end
    local plans = {}
    for _, cycleId in ipairs(cycleIds) do
        local plan, cycleError = buildCyclePlan(
            ledger,
            ledger.cyclesById[cycleId],
            currentYear
        )
        if plan == nil then
            return nil, cycleError
        end
        plans[#plans + 1] = plan
    end
    for _, plan in ipairs(plans) do
        local preservesQuery, preservationError = ledger:_retentionPlanPreservesQuery(plan)
        if not preservesQuery then
            return nil, preservationError
        end
    end
    local cumulativeDelta = 0
    for _, plan in ipairs(plans) do
        local planDelta, deltaError = ledger:_retentionPlanNeutralDelta(plan)
        if planDelta == nil then
            return nil, deltaError
        end
        cumulativeDelta = cumulativeDelta + planDelta
        local budgeted, budgetReason = ledger:_preflightNeutralDelta(
            cumulativeDelta
        )
        if not budgeted then
            return nil, budgetReason
        end
    end
    local results = {}
    for index, plan in ipairs(plans) do
        local result, applyError = applyCyclePlan(ledger, plan)
        if result == nil then
            return nil, applyError
        end
        results[index] = result
    end
    return results
end

function Retention.compactOldestClosedForCapacity(ledger, options)
    if not validLedger(ledger) then
        return nil, "invalidLedger"
    end
    options = options or {}
    if validateKnownFields(
            options,
            {excludeCycleId = true},
            "invalidCapacityCompactionOptions") == nil
        or (options.excludeCycleId ~= nil
            and type(options.excludeCycleId) ~= "string") then
        return nil, "invalidCapacityCompactionOptions"
    end
    local selectedCycle = nil
    for _, cycleId in ipairs(ledger.cycleOrder) do
        local cycle = ledger.cyclesById[cycleId]
        if cycleId ~= options.excludeCycleId
            and cycle.state == Constants.CYCLE_STATE.Closed
            and cycle.retentionSummary == nil then
            selectedCycle = cycle
            break
        end
    end
    if selectedCycle == nil then
        return {}
    end

    -- Calendar year zero is the canonical sentinel for capacity-triggered
    -- compaction. This path is deliberately independent of the user's
    -- calendar-year retention preference.
    local plan, planError = buildCyclePlan(ledger, selectedCycle, 0)
    if plan == nil then
        return nil, planError
    end
    local preservesQuery, preservationError =
        ledger:_retentionPlanPreservesQuery(plan)
    if not preservesQuery then
        return nil, preservationError
    end
    local planDelta, deltaError = ledger:_retentionPlanNeutralDelta(plan)
    if planDelta == nil then
        return nil, deltaError
    end
    local budgeted, budgetReason = ledger:_preflightNeutralDelta(planDelta)
    if not budgeted then
        return nil, budgetReason
    end
    local result, applyError = applyCyclePlan(ledger, plan)
    if result == nil then
        return nil, applyError
    end
    return {result}
end

FieldProfitabilityLedger.Core.Retention = Retention

return Retention
