FieldProfitabilityLedger = FieldProfitabilityLedger or {}
FieldProfitabilityLedger.Core = FieldProfitabilityLedger.Core or {}

local Core = FieldProfitabilityLedger.Core
local OperationCoordinator = {}
OperationCoordinator.__index = OperationCoordinator

local PRIVATE = setmetatable({}, {__mode = "k"})

local LEDGER_METHODS = {
    "checkpointCycleSessions",
    "closeCycle",
    "getOpenCycle",
    "getCycleBoundaryEvidence",
    "promoteCycleDescriptor",
    "createObservationId",
    "openCycle",
    "startSession",
    "recordEvidence",
    "acceptRecord",
    "closeSession",
    "expireSessions",
    "checkpointSessions"
}

local COMMAND_KEYS = {
    activeMs = true,
    attribution = true,
    changedAreaHa = true,
    fillType = true,
    fillTypeId = true,
    fruitType = true,
    fruitTypeId = true,
    implementIds = true,
    missionTime = true,
    observationDiscriminator = true,
    operationType = true,
    operatorId = true,
    operatorKind = true,
    operatorQuality = true,
    period = true,
    qualityClass = true,
    reasons = true,
    rootVehicleId = true,
    serverSequence = true,
    year = true
}

local OBSERVED_FACT_KEYS = {
    amount = true,
    category = true,
    metadata = true,
    observationDiscriminator = true,
    operationObservationDiscriminator = true,
    qualityClass = true,
    reasons = true,
    recordType = true,
    rootVehicleId = true,
    serverSequence = true,
    unit = true
}

local FACT_ONLY_KEYS = {
    activeMs = true,
    amount = true,
    attribution = true,
    category = true,
    implementIds = true,
    metadata = true,
    missionTime = true,
    observationDiscriminator = true,
    operationType = true,
    operatorId = true,
    operatorKind = true,
    operatorQuality = true,
    qualityClass = true,
    reasons = true,
    recordType = true,
    rootVehicleId = true,
    serverSequence = true,
    unit = true
}

local FACT_ONLY_METADATA_KEYS = {
    compatibilityProfile = true,
    consumerCount = true,
    fillName = true,
    fillTypeId = true,
    sourceCount = true
}

local APPLICATION_OPERATION = {
    seed = "seedingPlanting",
    fertilizer = "fertilizer",
    lime = "lime",
    herbicide = "herbicide",
    manure = "manure",
    slurry = "slurry",
    digestate = "digestate"
}

local ZERO_CHANGED_APPLICATION_CARRIER_KIND = "zeroChangedApplication"

local OBSERVED_FACT_SHAPES = {
    input = {
        seed = "litres", fertilizer = "litres", lime = "litres",
        herbicide = "litres", manure = "litres", slurry = "litres",
        digestate = "litres"
    },
    harvest = {harvest = "litres"},
    machinery = {
        fuel = "litres", def = "litres", workingTime = "milliseconds",
        wearDelta = "ratio"
    },
    labour = {
        aiLabourTime = "milliseconds", playerLabourTime = "milliseconds"
    }
}

local COALESCED_FACT_CATEGORIES = {
    seed = true, fertilizer = true, lime = true, herbicide = true,
    manure = true, slurry = true, digestate = true, harvest = true,
    fuel = true, def = true, workingTime = true,
    aiLabourTime = true, playerLabourTime = true
}

local ATTRIBUTION_KEYS = {
    baseField = {
        cycleAreaHa = true,
        farmId = true,
        farmlandId = true,
        fieldId = true,
        fieldKind = true,
        kind = true,
        landKey = true,
        qualityClass = true,
        reasons = true
    },
    parcel = {
        farmId = true,
        farmlandId = true,
        fieldKind = true,
        kind = true,
        landKey = true,
        qualityClass = true,
        reasons = true
    },
    mixed = {
        candidateLandKeys = true,
        farmId = true,
        kind = true,
        landKey = true,
        qualityClass = true,
        reasons = true
    }
}

local OPERATOR_KINDS = {
    ai = true,
    player = true,
    unknown = true
}

local QUALITY_RANK = {
    Complete = 1,
    Partial = 2,
    Unsupported = 3
}

local function dependencies()
    local constants = rawget(Core, "Constants")
    local validation = rawget(Core, "Validation")
    local identifiers = rawget(Core, "Identifiers")
    if type(constants) ~= "table"
        or type(rawget(constants, "LIMITS")) ~= "table"
        or type(validation) ~= "table"
        or type(validation.array) ~= "function"
        or type(validation.asciiToken) ~= "function"
        or type(validation.copy) ~= "function"
        or type(validation.integer) ~= "function"
        or type(validation.number) ~= "function"
        or type(identifiers) ~= "table"
        or type(identifiers.compare) ~= "function"
        or type(identifiers.parseLandKey) ~= "function"
        or type(identifiers.parseObservationId) ~= "function" then
        return nil, nil, nil, "coreDependencyUnavailable"
    end
    return constants, validation, identifiers
end

local function compareBytes(left, right)
    local sharedLength = math.min(#left, #right)
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

local function byteLess(left, right)
    return compareBytes(left, right) < 0
end

local function knownFields(value, allowed, reason)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        return nil, reason
    end
    local maximum = 0
    for _ in pairs(allowed) do
        maximum = maximum + 1
    end
    local count = 0
    for key in next, value do
        count = count + 1
        if count > maximum or type(key) ~= "string" or allowed[key] ~= true then
            return nil, reason
        end
    end
    return value
end

local function copyLimits(constants, maximumItems)
    return {
        maxDepth = constants.LIMITS.maxNeutralDepth,
        maxItems = maximumItems or constants.LIMITS.maxNeutralItems,
        maxStringBytes = constants.LIMITS.textBytes,
        maxNumber = math.max(
            constants.LIMITS.maxIdentifier,
            constants.LIMITS.maxDurationMs,
            constants.LIMITS.maxMoney
        )
    }
end

local function detachedCopy(value, maximumItems)
    local constants, validation, _, dependencyError = dependencies()
    if constants == nil then
        return nil, dependencyError
    end
    return validation.copy(value, copyLimits(constants, maximumItems))
end

local function validateToken(validation, constants, value, maximumBytes)
    return validation.asciiToken(
        value,
        maximumBytes or constants.LIMITS.tokenBytes
    )
end

local function normalizeReasons(validation, constants, value)
    local reasons, arrayError = validation.array(
        value,
        constants.LIMITS.maxReasons
    )
    if reasons == nil then
        return nil, arrayError
    end
    local normalized = {}
    local seen = {}
    for _, candidate in ipairs(reasons) do
        local reason, reasonError = validateToken(
            validation,
            constants,
            candidate
        )
        if reason == nil then
            return nil, reasonError
        end
        if not seen[reason] then
            seen[reason] = true
            normalized[#normalized + 1] = reason
        end
    end
    table.sort(normalized, byteLess)
    return normalized
end

local function validateAttributionReasons(validation, constants, value)
    local reasons, arrayError = validation.array(
        value,
        constants.LIMITS.maxReasons
    )
    if reasons == nil then
        return nil, arrayError
    end
    local normalized = {}
    for index, candidate in ipairs(reasons) do
        local reason, reasonError = validateToken(
            validation,
            constants,
            candidate
        )
        if reason == nil then
            return nil, reasonError
        end
        normalized[index] = reason
    end
    return normalized
end

local function mergeReasons(constants, left, right)
    local result = {}
    local seen = {}
    for _, source in ipairs({left or {}, right or {}}) do
        for _, reason in ipairs(source) do
            if not seen[reason] then
                if #result >= constants.LIMITS.maxReasons then
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

local function lowerQuality(left, right)
    if QUALITY_RANK[left] >= QUALITY_RANK[right] then
        return left
    end
    return right
end

local function validateAttribution(value, constants, validation, identifiers)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        return nil, "invalidAttribution"
    end
    local kind = rawget(value, "kind")
    local allowed = ATTRIBUTION_KEYS[kind]
    if allowed == nil or knownFields(value, allowed, "invalidAttribution") == nil then
        return nil, "invalidAttribution"
    end

    local landKey = rawget(value, "landKey")
    local landParts, landError = identifiers.parseLandKey(landKey)
    if landParts == nil then
        return nil, landError
    end
    local farmId, numericError = validation.integer(
        rawget(value, "farmId"),
        1,
        constants.LIMITS.maxIdentifier
    )
    if farmId == nil then
        return nil, numericError
    end
    if farmId ~= landParts.farmId then
        return nil, "attributionLandMismatch"
    end
    local qualityClass = rawget(value, "qualityClass")
    if qualityClass ~= constants.QUALITY_CLASS.Complete
        and qualityClass ~= constants.QUALITY_CLASS.Partial then
        return nil, "invalidAttributionQuality"
    end
    local reasons, reasonsError = validateAttributionReasons(
        validation,
        constants,
        rawget(value, "reasons")
    )
    if reasons == nil then
        return nil, reasonsError
    end

    local normalized = {
        kind = kind,
        landKey = landKey,
        farmId = farmId,
        qualityClass = qualityClass,
        reasons = reasons
    }
    if kind == "baseField" then
        local farmlandId = nil
        farmlandId, numericError = validation.integer(
            rawget(value, "farmlandId"),
            1,
            constants.LIMITS.maxIdentifier
        )
        if farmlandId == nil then
            return nil, numericError
        end
        local fieldId = nil
        fieldId, numericError = validation.integer(
            rawget(value, "fieldId"),
            1,
            constants.LIMITS.maxIdentifier
        )
        if fieldId == nil then
            return nil, numericError
        end
        if rawget(value, "fieldKind") ~= "base"
            or landParts.fieldKind ~= "base"
            or farmlandId ~= landParts.farmlandId
            or fieldId ~= landParts.fieldId then
            return nil, "attributionLandMismatch"
        end
        if qualityClass ~= constants.QUALITY_CLASS.Complete or #reasons ~= 0 then
            return nil, "invalidBaseFieldAttribution"
        end
        local cycleAreaHa = rawget(value, "cycleAreaHa")
        if cycleAreaHa ~= nil then
            cycleAreaHa, numericError = validation.number(
                cycleAreaHa,
                0,
                constants.LIMITS.maxAreaHa
            )
            if cycleAreaHa == nil then
                return nil, numericError
            end
            if cycleAreaHa == 0 then
                return nil, "belowMinimum"
            end
        end
        normalized.farmlandId = farmlandId
        normalized.fieldId = fieldId
        normalized.fieldKind = "base"
        normalized.cycleAreaHa = cycleAreaHa
    elseif kind == "parcel" then
        local farmlandId = nil
        farmlandId, numericError = validation.integer(
            rawget(value, "farmlandId"),
            1,
            constants.LIMITS.maxIdentifier
        )
        if farmlandId == nil then
            return nil, numericError
        end
        if rawget(value, "fieldKind") ~= "parcel"
            or landParts.fieldKind ~= "parcel"
            or farmlandId ~= landParts.farmlandId then
            return nil, "attributionLandMismatch"
        end
        local ordinaryParcel = #reasons == 1
            and reasons[1] == "parcelFallback"
        local customParcel = #reasons == 2
            and reasons[1] == "customFieldGeometry"
            and reasons[2] == "parcelFallback"
        if qualityClass ~= constants.QUALITY_CLASS.Partial
            or (not ordinaryParcel and not customParcel) then
            return nil, "invalidParcelAttribution"
        end
        normalized.farmlandId = farmlandId
        normalized.fieldKind = "parcel"
    else
        if qualityClass ~= constants.QUALITY_CLASS.Partial
            or #reasons ~= 1
            or reasons[1] ~= "boundaryUnresolved" then
            return nil, "invalidMixedAttribution"
        end
        local candidates, candidatesError = validation.array(
            rawget(value, "candidateLandKeys"),
            constants.LIMITS.maxBoundaryCandidates
        )
        if candidates == nil or #candidates < 2 then
            return nil, candidatesError or "mixedBoundaryCandidatesRequired"
        end
        local normalizedCandidates = {}
        local previous = nil
        local candidateFarmlands = {}
        local candidateFarmlandCount = 0
        for index, candidate in ipairs(candidates) do
            local candidateParts, candidateError = identifiers.parseLandKey(candidate)
            if candidateParts == nil then
                return nil, candidateError
            end
            if candidateParts.farmId ~= farmId then
                return nil, "mixedBoundaryFarmMismatch"
            end
            if previous ~= nil and compareBytes(previous, candidate) >= 0 then
                return nil, "nonCanonicalBoundaryCandidates"
            end
            previous = candidate
            normalizedCandidates[index] = candidate
            local farmlandState = candidateFarmlands[candidateParts.farmlandId]
            if farmlandState == nil then
                candidateFarmlandCount = candidateFarmlandCount + 1
                if candidateFarmlandCount > 5 then
                    return nil, "invalidMixedAttribution"
                end
                farmlandState = {}
                candidateFarmlands[candidateParts.farmlandId] = farmlandState
            end
            farmlandState[candidateParts.fieldKind] = true
        end
        for _, farmlandState in pairs(candidateFarmlands) do
            if farmlandState.base == true and farmlandState.parcel ~= true then
                return nil, "invalidMixedAttribution"
            end
        end
        if normalizedCandidates[1] ~= landKey then
            return nil, "mixedBoundaryPrimaryMismatch"
        end
        normalized.candidateLandKeys = normalizedCandidates
    end
    return normalized
end

local function normalizeImplementIds(value, constants, validation)
    local implementations, arrayError = validation.array(
        value,
        constants.LIMITS.maxReferences
    )
    if implementations == nil then
        return nil, arrayError
    end
    local result = {}
    local seen = {}
    for _, candidate in ipairs(implementations) do
        local implementId, implementError = validateToken(
            validation,
            constants,
            candidate,
            constants.LIMITS.idBytes
        )
        if implementId == nil then
            return nil, implementError
        end
        if not seen[implementId] then
            seen[implementId] = true
            result[#result + 1] = implementId
        end
    end
    table.sort(result, byteLess)
    return result
end

local function normalizeCommand(command)
    local constants, validation, identifiers, dependencyError = dependencies()
    if constants == nil then
        return nil, dependencyError
    end
    if type(command) ~= "table" or getmetatable(command) ~= nil then
        return nil, "invalidCommand"
    end
    if knownFields(command, COMMAND_KEYS, "invalidCommand") == nil then
        return nil, "invalidCommand"
    end
    local copied, copyError = validation.copy(
        command,
        copyLimits(constants, constants.LIMITS.maxComponents)
    )
    if copied == nil then
        return nil, copyError
    end
    if knownFields(copied, COMMAND_KEYS, "invalidCommand") == nil then
        return nil, "invalidCommand"
    end

    local attribution, attributionError = validateAttribution(
        rawget(copied, "attribution"),
        constants,
        validation,
        identifiers
    )
    if attribution == nil then
        return nil, attributionError
    end
    local operationType, operationError = validateToken(
        validation,
        constants,
        rawget(copied, "operationType")
    )
    if operationType == nil or constants.OPERATION[operationType] ~= true then
        return nil, operationError or "unsupportedOperation"
    end
    local changedAreaHa, numericError = validation.number(
        rawget(copied, "changedAreaHa"),
        0,
        constants.LIMITS.maxAreaHa
    )
    if changedAreaHa == nil then
        return nil, numericError
    end
    if changedAreaHa <= 0 then
        return nil, "positiveAreaRequired"
    end
    local rootVehicleId, tokenError = validateToken(
        validation,
        constants,
        rawget(copied, "rootVehicleId"),
        constants.LIMITS.idBytes
    )
    if rootVehicleId == nil then
        return nil, tokenError
    end
    local implementIds, implementError = normalizeImplementIds(
        rawget(copied, "implementIds"),
        constants,
        validation
    )
    if implementIds == nil then
        return nil, implementError
    end
    local missionTime = nil
    missionTime, numericError = validation.number(
        rawget(copied, "missionTime"),
        0,
        constants.LIMITS.maxMissionTime
    )
    if missionTime == nil then
        return nil, numericError
    end
    local serverSequence = nil
    serverSequence, numericError = validation.integer(
        rawget(copied, "serverSequence"),
        1,
        constants.LIMITS.maxIdentifier
    )
    if serverSequence == nil then
        return nil, numericError
    end
    local activeMs = nil
    activeMs, numericError = validation.number(
        rawget(copied, "activeMs"),
        0,
        constants.LIMITS.maxDurationMs
    )
    if activeMs == nil then
        return nil, numericError
    end
    local observationDiscriminator = nil
    observationDiscriminator, tokenError = validateToken(
        validation,
        constants,
        rawget(copied, "observationDiscriminator"),
        constants.LIMITS.idBytes
    )
    if observationDiscriminator == nil then
        return nil, tokenError
    end
    local period = nil
    period, numericError = validation.integer(
        rawget(copied, "period"),
        1,
        constants.LIMITS.maxPeriod
    )
    if period == nil then
        return nil, numericError
    end
    local year = rawget(copied, "year")
    if year ~= nil then
        year, numericError = validation.integer(
            year,
            0,
            constants.LIMITS.maxYear
        )
        if year == nil then
            return nil, numericError
        end
    end
    local fruitType = nil
    fruitType, tokenError = validateToken(
        validation,
        constants,
        rawget(copied, "fruitType")
    )
    if fruitType == nil then
        return nil, tokenError
    end
    local fruitTypeId = rawget(copied, "fruitTypeId")
    if fruitTypeId ~= nil then
        fruitTypeId, numericError = validation.integer(
            fruitTypeId,
            0,
            constants.LIMITS.maxIdentifier
        )
        if fruitTypeId == nil then
            return nil, numericError
        end
    end
    local fillType = rawget(copied, "fillType")
    if fillType ~= nil then
        fillType, tokenError = validateToken(validation, constants, fillType)
        if fillType == nil then
            return nil, tokenError
        end
    end
    local fillTypeId = rawget(copied, "fillTypeId")
    if fillTypeId ~= nil then
        fillTypeId, numericError = validation.integer(
            fillTypeId,
            0,
            constants.LIMITS.maxIdentifier
        )
        if fillTypeId == nil then
            return nil, numericError
        end
    end
    local operatorKind = nil
    operatorKind, tokenError = validateToken(
        validation,
        constants,
        rawget(copied, "operatorKind")
    )
    if operatorKind == nil or OPERATOR_KINDS[operatorKind] ~= true then
        return nil, tokenError or "invalidOperatorKind"
    end
    local operatorId = rawget(copied, "operatorId")
    if operatorId ~= nil then
        operatorId, tokenError = validateToken(
            validation,
            constants,
            operatorId,
            constants.LIMITS.idBytes
        )
        if operatorId == nil then
            return nil, tokenError
        end
    end
    local operatorQuality = rawget(copied, "operatorQuality")
        or constants.QUALITY_CLASS.Partial
    if constants.QUALITY_CLASS_SET[operatorQuality] ~= true then
        return nil, "invalidOperatorQuality"
    end
    if operatorKind == "unknown"
        and (operatorId ~= nil
            or operatorQuality == constants.QUALITY_CLASS.Complete) then
        return nil, "invalidOperatorContext"
    end
    local qualityClass = rawget(copied, "qualityClass")
    if qualityClass ~= constants.QUALITY_CLASS.Complete
        and qualityClass ~= constants.QUALITY_CLASS.Partial then
        return nil, "invalidQualityClass"
    end
    local reasons, reasonsError = normalizeReasons(
        validation,
        constants,
        rawget(copied, "reasons")
    )
    if reasons == nil then
        return nil, reasonsError
    end
    if qualityClass ~= constants.QUALITY_CLASS.Complete and #reasons == 0 then
        return nil, "qualityReasonRequired"
    end
    local combinedReasons = nil
    combinedReasons, reasonsError = mergeReasons(
        constants,
        attribution.reasons,
        reasons
    )
    if combinedReasons == nil then
        return nil, reasonsError
    end
    local combinedQuality = lowerQuality(
        attribution.qualityClass,
        qualityClass
    )
    if combinedQuality ~= constants.QUALITY_CLASS.Complete
        and #combinedReasons == 0 then
        return nil, "qualityReasonRequired"
    end
    local sessionReasons = combinedReasons
    if operatorQuality ~= constants.QUALITY_CLASS.Complete then
        sessionReasons, reasonsError = mergeReasons(
            constants,
            sessionReasons,
            {"operatorUnavailable"}
        )
        if sessionReasons == nil then
            return nil, reasonsError
        end
    end

    return {
        attribution = attribution,
        operationType = operationType,
        changedAreaHa = changedAreaHa,
        rootVehicleId = rootVehicleId,
        implementIds = implementIds,
        missionTime = missionTime,
        serverSequence = serverSequence,
        activeMs = activeMs,
        observationDiscriminator = observationDiscriminator,
        period = period,
        year = year,
        fruitType = fruitType,
        fruitTypeId = fruitTypeId,
        fillType = fillType,
        fillTypeId = fillTypeId,
        operatorKind = operatorKind,
        operatorId = operatorId,
        operatorQuality = operatorQuality,
        qualityClass = combinedQuality,
        reasons = combinedReasons,
        sessionReasons = sessionReasons
    }
end

local function normalizeObservedFact(value)
    local constants, validation, _, dependencyError = dependencies()
    if constants == nil then return nil, dependencyError end
    if type(value) ~= "table" or getmetatable(value) ~= nil
        or knownFields(value, OBSERVED_FACT_KEYS, "invalidObservedFact") == nil then
        return nil, "invalidObservedFact"
    end
    local copied, copyError = validation.copy(
        value,
        copyLimits(constants, constants.LIMITS.maxComponents)
    )
    if copied == nil then return nil, copyError end
    if knownFields(copied, OBSERVED_FACT_KEYS, "invalidObservedFact") == nil then
        return nil, "invalidObservedFact"
    end

    local rootVehicleId, reason = validateToken(
        validation, constants, rawget(copied, "rootVehicleId"),
        constants.LIMITS.idBytes)
    if rootVehicleId == nil then return nil, reason end
    local serverSequence = nil
    serverSequence, reason = validation.integer(
        rawget(copied, "serverSequence"), 1, constants.LIMITS.maxIdentifier)
    if serverSequence == nil then return nil, reason end
    local discriminator = nil
    discriminator, reason = validateToken(
        validation, constants, rawget(copied, "observationDiscriminator"),
        constants.LIMITS.idBytes)
    if discriminator == nil then return nil, reason end
    local operationDiscriminator = nil
    operationDiscriminator, reason = validateToken(
        validation, constants,
        rawget(copied, "operationObservationDiscriminator"),
        constants.LIMITS.idBytes)
    if operationDiscriminator == nil then return nil, reason end

    local recordType = rawget(copied, "recordType")
    local shapes = OBSERVED_FACT_SHAPES[recordType]
    if shapes == nil then return nil, "unsupportedObservedFact" end
    local category = rawget(copied, "category")
    local expectedUnit = shapes[category]
    if expectedUnit == nil or constants.CATEGORY_SET[category] ~= true then
        return nil, "unsupportedObservedFact"
    end
    local unit = rawget(copied, "unit")
    if unit ~= expectedUnit then return nil, "unsupportedObservedFact" end
    local maximum = constants.UNIT_LIMIT[unit]
    local amount = nil
    amount, reason = validation.number(rawget(copied, "amount"), 0, maximum)
    if amount == nil then return nil, reason end
    if amount <= 0 then return nil, "positiveAmountRequired" end

    local quality = rawget(copied, "qualityClass")
    if quality ~= constants.QUALITY_CLASS.Complete
        and quality ~= constants.QUALITY_CLASS.Partial then
        return nil, "invalidObservedFactQuality"
    end
    local reasons = nil
    reasons, reason = normalizeReasons(
        validation, constants, rawget(copied, "reasons"))
    if reasons == nil then return nil, reason end
    if quality == constants.QUALITY_CLASS.Partial and #reasons == 0 then
        return nil, "qualityReasonRequired"
    end
    local metadata = rawget(copied, "metadata") or {}
    metadata, reason = validation.copy(
        metadata,
        copyLimits(constants, constants.LIMITS.maxComponents)
    )
    if metadata == nil or type(metadata) ~= "table" then
        return nil, reason or "invalidRecordMetadata"
    end

    return {
        rootVehicleId = rootVehicleId,
        serverSequence = serverSequence,
        observationDiscriminator = discriminator,
        operationObservationDiscriminator = operationDiscriminator,
        recordType = recordType,
        category = category,
        amount = amount,
        unit = unit,
        qualityClass = quality,
        reasons = reasons,
        metadata = metadata
    }
end

local function normalizeFactOnly(value)
    local constants, validation, identifiers, dependencyError = dependencies()
    if constants == nil then return nil, dependencyError end
    if type(value) ~= "table" or getmetatable(value) ~= nil
        or knownFields(value, FACT_ONLY_KEYS, "invalidFactOnly") == nil then
        return nil, "invalidFactOnly"
    end
    local copied, copyError = validation.copy(
        value, copyLimits(constants, constants.LIMITS.maxComponents))
    if copied == nil then return nil, copyError end
    if knownFields(copied, FACT_ONLY_KEYS, "invalidFactOnly") == nil then
        return nil, "invalidFactOnly"
    end

    local attribution, reason = validateAttribution(
        rawget(copied, "attribution"), constants, validation, identifiers)
    if attribution == nil then return nil, reason end
    if attribution.kind ~= "baseField" and attribution.kind ~= "parcel" then
        return nil, "factOnlyAttributionRequired"
    end
    local rootVehicleId = nil
    rootVehicleId, reason = validateToken(
        validation, constants, rawget(copied, "rootVehicleId"),
        constants.LIMITS.idBytes)
    if rootVehicleId == nil then return nil, reason end
    local serverSequence = nil
    serverSequence, reason = validation.integer(
        rawget(copied, "serverSequence"), 1, constants.LIMITS.maxIdentifier)
    if serverSequence == nil then return nil, reason end
    local missionTime = nil
    missionTime, reason = validation.number(
        rawget(copied, "missionTime"), 0, constants.LIMITS.maxMissionTime)
    if missionTime == nil then return nil, reason end
    local activeMs = nil
    activeMs, reason = validation.number(
        rawget(copied, "activeMs"), 0, constants.LIMITS.maxDurationMs)
    if activeMs == nil then return nil, reason end
    local implementIds = nil
    implementIds, reason = normalizeImplementIds(
        rawget(copied, "implementIds"), constants, validation)
    if implementIds == nil then return nil, reason end

    local category = nil
    category, reason = validateToken(
        validation, constants, rawget(copied, "category"))
    local expectedOperation = category ~= nil
        and APPLICATION_OPERATION[category] or nil
    local operationType = nil
    operationType, reason = validateToken(
        validation, constants, rawget(copied, "operationType"))
    local discriminator = nil
    discriminator, reason = validateToken(
        validation, constants, rawget(copied, "observationDiscriminator"),
        constants.LIMITS.idBytes)
    if rawget(copied, "recordType") ~= constants.RECORD_TYPE.Input
        or rawget(copied, "unit") ~= constants.UNIT.Litres
        or rawget(copied, "qualityClass") ~= constants.QUALITY_CLASS.Partial
        or expectedOperation == nil or operationType ~= expectedOperation
        or discriminator == nil then
        return nil, "invalidFactOnly"
    end
    local amount = nil
    amount, reason = validation.number(
        rawget(copied, "amount"), 0, constants.LIMITS.maxPhysical)
    if amount == nil then return nil, reason end
    if amount <= 0 then return nil, "positiveAmountRequired" end
    local suppliedReasons = nil
    suppliedReasons, reason = validation.array(
        rawget(copied, "reasons"), constants.LIMITS.maxReasons)
    if suppliedReasons == nil then return nil, reason end
    if #suppliedReasons ~= 1 or suppliedReasons[1] ~= "zeroChangedArea" then
        return nil, "invalidFactOnlyReason"
    end

    local metadata = rawget(copied, "metadata")
    if knownFields(metadata, FACT_ONLY_METADATA_KEYS,
        "invalidFactOnlyMetadata") == nil then
        return nil, "invalidFactOnlyMetadata"
    end
    local compatibilityProfile = nil
    compatibilityProfile, reason = validateToken(
        validation, constants, rawget(metadata, "compatibilityProfile"),
        constants.LIMITS.textBytes)
    if compatibilityProfile == nil then return nil, reason end
    local fillName = nil
    fillName, reason = validateToken(
        validation, constants, rawget(metadata, "fillName"),
        constants.LIMITS.textBytes)
    if fillName == nil then return nil, reason end
    local consumerCount = nil
    consumerCount, reason = validation.integer(
        rawget(metadata, "consumerCount"), 1,
        constants.LIMITS.maxReferences)
    if consumerCount == nil then return nil, reason end
    local sourceCount = nil
    sourceCount, reason = validation.integer(
        rawget(metadata, "sourceCount"), 1,
        constants.LIMITS.maxReferences)
    if sourceCount == nil then return nil, reason end
    local fillTypeId = rawget(metadata, "fillTypeId")
    if fillTypeId ~= nil then
        fillTypeId, reason = validation.integer(
            fillTypeId, 0, constants.LIMITS.maxIdentifier)
        if fillTypeId == nil then return nil, reason end
    end

    local operatorKind = nil
    operatorKind, reason = validateToken(
        validation, constants, rawget(copied, "operatorKind"))
    if operatorKind == nil or OPERATOR_KINDS[operatorKind] ~= true then
        return nil, reason or "invalidOperatorKind"
    end
    local operatorId = rawget(copied, "operatorId")
    if operatorId ~= nil then
        operatorId, reason = validateToken(
            validation, constants, operatorId, constants.LIMITS.idBytes)
        if operatorId == nil then return nil, reason end
    end
    local operatorQuality = rawget(copied, "operatorQuality")
    if constants.QUALITY_CLASS_SET[operatorQuality] ~= true then
        return nil, "invalidOperatorQuality"
    end
    if operatorKind == "unknown"
        and (operatorId ~= nil
            or operatorQuality == constants.QUALITY_CLASS.Complete) then
        return nil, "invalidOperatorContext"
    end
    local recordReasons = {"zeroChangedArea"}
    local sessionReasons = nil
    sessionReasons, reason = mergeReasons(
        constants, attribution.reasons, recordReasons)
    if sessionReasons == nil then return nil, reason end
    if operatorQuality ~= constants.QUALITY_CLASS.Complete then
        sessionReasons, reason = mergeReasons(
            constants, sessionReasons, {"operatorUnavailable"})
        if sessionReasons == nil then return nil, reason end
    end
    return {
        activeMs = activeMs,
        amount = amount,
        attribution = attribution,
        category = category,
        carrierKind = ZERO_CHANGED_APPLICATION_CARRIER_KIND,
        implementIds = implementIds,
        metadata = {
            compatibilityProfile = compatibilityProfile,
            consumerCount = consumerCount,
            fillName = fillName,
            fillTypeId = fillTypeId,
            sourceCount = sourceCount
        },
        missionTime = missionTime,
        observationDiscriminator = discriminator,
        operationType = operationType,
        operatorId = operatorId,
        operatorKind = operatorKind,
        operatorQuality = operatorQuality,
        qualityClass = constants.QUALITY_CLASS.Partial,
        reasons = recordReasons,
        recordType = constants.RECORD_TYPE.Input,
        rootVehicleId = rootVehicleId,
        serverSequence = serverSequence,
        sessionReasons = sessionReasons,
        unit = constants.UNIT.Litres
    }
end

local function safeMethod(value, name)
    local ok, method = pcall(function()
        return value[name]
    end)
    if not ok or type(method) ~= "function" then
        return nil
    end
    return method
end

local function normalizeLedgerReason(reason)
    local constants, validation = dependencies()
    if constants ~= nil and type(reason) == "string" then
        local accepted = validation.asciiToken(
            reason,
            constants.LIMITS.tokenBytes
        )
        if accepted ~= nil then
            return accepted
        end
    end
    return "ledgerRejected"
end

local function callLedger(state, name, ...)
    local ok, first, second, third = pcall(
        state.methods[name],
        state.ledger,
        ...
    )
    if not ok then
        return nil, "ledgerCallFailed"
    end
    if first == nil then
        return nil, normalizeLedgerReason(second)
    end
    return first, second, third
end

local function normalizeCycleDto(value, expectedLandKey)
    local constants, validation = dependencies()
    local copied = detachedCopy(value)
    if copied == nil or type(copied) ~= "table" then
        return nil, "invalidLedgerResult"
    end
    local id = validateToken(
        validation,
        constants,
        rawget(copied, "id"),
        constants.LIMITS.idBytes
    )
    if id == nil
        or rawget(copied, "landKey") ~= expectedLandKey
        or rawget(copied, "state") ~= constants.CYCLE_STATE.Open then
        return nil, "invalidLedgerResult"
    end
    return copied
end

local function normalizeSessionDto(value, command, cycleId)
    local constants, validation = dependencies()
    local copied = detachedCopy(value)
    if copied == nil or type(copied) ~= "table" then
        return nil, "invalidLedgerResult"
    end
    local id = validateToken(
        validation,
        constants,
        rawget(copied, "id"),
        constants.LIMITS.idBytes
    )
    if id == nil
        or rawget(copied, "cycleId") ~= cycleId
        or rawget(copied, "landKey") ~= command.attribution.landKey
        or rawget(copied, "rootVehicleId") ~= command.rootVehicleId
        or rawget(copied, "carrierKind") ~= command.carrierKind
        or rawget(copied, "state") ~= constants.SESSION_STATE.Open then
        return nil, "invalidLedgerResult"
    end
    return copied
end

local function normalizeRecordDto(value, command, cycleId, sessionId, observationId)
    local constants, validation = dependencies()
    local copied = detachedCopy(value)
    if copied == nil or type(copied) ~= "table" then
        return nil, "invalidLedgerResult"
    end
    local id = validateToken(
        validation,
        constants,
        rawget(copied, "id"),
        constants.LIMITS.idBytes
    )
    local expectedCategory = command.attribution.kind == "mixed"
        and "mixedBoundaryTick"
        or command.operationType
    if id == nil
        or rawget(copied, "cycleId") ~= cycleId
        or rawget(copied, "sessionId") ~= sessionId
        or rawget(copied, "observationId") ~= observationId
        or rawget(copied, "recordType") ~= constants.RECORD_TYPE.Operation
        or rawget(copied, "category") ~= expectedCategory
        or rawget(copied, "accountingClass")
            ~= constants.ACCOUNTING_CLASS.Observed
        or rawget(copied, "amount") ~= command.changedAreaHa
        or rawget(copied, "unit") ~= constants.UNIT.Hectares then
        return nil, "invalidLedgerResult"
    end
    return copied
end

local function addDiagnostic(state, stage, command, reason)
    local constants = dependencies()
    local row = {
        stage = stage,
        rootVehicleId = command.rootVehicleId,
        missionTime = command.missionTime,
        reason = normalizeLedgerReason(reason)
    }
    if #state.diagnostics < constants.LIMITS.maxLoadDiagnostics then
        state.diagnostics[#state.diagnostics + 1] = row
    else
        state.omittedDiagnostics = state.omittedDiagnostics + 1
    end
end

local function clearRoot(state, rootVehicleId)
    local tracked = state.sessionsByRoot[rootVehicleId]
    if tracked ~= nil then
        state.rootBySession[tracked.sessionId] = nil
    end
    state.sessionsByRoot[rootVehicleId] = nil
    state.sequenceContextsByRoot[rootVehicleId] = nil
    state.lastSequenceByRoot[rootVehicleId] = nil
end

local function clearSession(state, sessionId)
    local rootVehicleId = state.rootBySession[sessionId]
    if rootVehicleId ~= nil then
        clearRoot(state, rootVehicleId)
    end
end

local function trackSession(state, command, session)
    local previous = state.sessionsByRoot[command.rootVehicleId]
    if previous ~= nil and previous.sessionId ~= session.id then
        state.rootBySession[previous.sessionId] = nil
    end
    local _, _, identifiers = dependencies()
    local candidateFarmlands = {}
    if command.attribution.kind == "mixed" then
        for _, candidate in ipairs(command.attribution.candidateLandKeys) do
            local parts = identifiers.parseLandKey(candidate)
            candidateFarmlands[parts.farmlandId] = true
        end
    else
        candidateFarmlands[command.attribution.farmlandId] = true
    end
    state.sessionsByRoot[command.rootVehicleId] = {
        sessionId = session.id,
        rootVehicleId = command.rootVehicleId,
        landKey = command.attribution.landKey,
        farmId = command.attribution.farmId,
        candidateFarmlands = candidateFarmlands,
        lastEvidenceTime = rawget(session, "lastEvidenceTime")
            or command.missionTime,
        session = session
    }
    state.rootBySession[session.id] = command.rootVehicleId
end

local function sameArray(left, right)
    if #left ~= #right then
        return false
    end
    for index = 1, #left do
        if left[index] ~= right[index] then
            return false
        end
    end
    return true
end

local function compatibleEvidence(context, command)
    return context.missionTime == command.missionTime
        and context.activeMs == command.activeMs
        and context.fillType == command.fillType
        and context.fillTypeId == command.fillTypeId
        and context.operatorKind == command.operatorKind
        and context.operatorId == command.operatorId
        and context.operatorQuality == command.operatorQuality
        and sameArray(context.implementIds, command.implementIds)
end

local function sameAttributionLandContext(context, attribution)
    if context.landKey ~= attribution.landKey
        or context.attributionKind ~= attribution.kind then
        return false
    end
    if attribution.kind ~= "mixed" then
        return true
    end
    return sameArray(
        context.candidateLandKeys,
        attribution.candidateLandKeys
    )
end

local function sequenceDisposition(state, command)
    local lastSequence = state.lastSequenceByRoot[command.rootVehicleId]
    if lastSequence == nil then
        return "new"
    end
    if command.serverSequence < lastSequence then
        return nil, "outOfOrderSequence"
    elseif command.serverSequence > lastSequence then
        local previous = state.sequenceContextsByRoot[command.rootVehicleId]
        if previous ~= nil and command.missionTime < previous.missionTime then
            return nil, "outOfOrderEvidence"
        end
        return "new"
    end
    local context = state.sequenceContextsByRoot[command.rootVehicleId]
    if context == nil then
        return nil, "evidenceSequenceCollision"
    end
    if not sameAttributionLandContext(context, command.attribution) then
        return nil, "sequenceLandCollision"
    end
    if not compatibleEvidence(context, command) then
        return nil, "evidenceSequenceCollision"
    end
    local tracked = state.sessionsByRoot[command.rootVehicleId]
    if tracked == nil or tracked.sessionId ~= context.session.id then
        return nil, "evidenceSequenceCollision"
    end
    return "same", context
end

local function makeMetadata(command)
    local attribution = command.attribution
    local metadata = {
        attributionKind = attribution.kind,
        observationDiscriminator = command.observationDiscriminator,
        serverSequence = command.serverSequence
    }
    if attribution.kind == "mixed" then
        metadata.candidateLandKeys = {}
        for index, candidate in ipairs(attribution.candidateLandKeys) do
            metadata.candidateLandKeys[index] = candidate
        end
    else
        metadata.farmId = attribution.farmId
        metadata.farmlandId = attribution.farmlandId
        metadata.fieldKind = attribution.fieldKind
        metadata.fieldId = attribution.fieldId
    end
    return metadata
end

local function attemptRejectedClose(state, command, tracked)
    if tracked == nil then
        return
    end
    local closed = callLedger(state, "closeSession", {
        sessionId = tracked.sessionId,
        reason = "recordRejected",
        endMissionTime = command.missionTime
    })
    if closed ~= nil then
        clearRoot(state, command.rootVehicleId)
    end
end

local function cycleDescriptorConflicts(cycle, command)
    -- Runtime collectors can prove the selected crop only for establishment
    -- and harvest.  Ordinary later work therefore reports "unknown"/nil,
    -- which is absence of new crop evidence rather than a contradiction of an
    -- established cycle.  Numeric fruit IDs are likewise comparable only when
    -- both observations are present.  fillTypeId is deliberately excluded:
    -- application material and harvest output share that transport field, so
    -- it is not reliable evidence that the immutable crop descriptor changed.
    local cycleFruitType = rawget(cycle, "fruitType")
    if command.fruitType ~= "unknown" and cycleFruitType ~= "unknown"
        and cycleFruitType ~= command.fruitType then
        return true
    end
    local cycleFruitTypeId = rawget(cycle, "fruitTypeId")
    return cycleFruitTypeId ~= nil
        and command.fruitTypeId ~= nil
        and cycleFruitTypeId ~= command.fruitTypeId
end

local function automaticBoundaryReason(constants, cycle, command, evidence,
        disposition)
    if disposition ~= "new" then
        return nil
    end
    -- A mixed boundary marker is deliberately unresolved and unallocated.
    -- Its primary landKey is only the first canonical candidate, so it cannot
    -- prove that candidate crossed a crop-cycle boundary.
    if command.attribution.kind == "mixed" then
        return nil
    end
    if command.operationType == "seedingPlanting"
        and cycleDescriptorConflicts(cycle, command) then
        return "automaticCropChangeBoundary"
    end
    if evidence.hasHarvest == true
        and command.operationType ~= "ordinaryArableHarvest" then
        return "automaticPostHarvestBoundary"
    end
    return nil
end

local function rejectAfterStage(
    state,
    stage,
    command,
    reason,
    mutationOccurred,
    tracked
)
    if mutationOccurred then
        addDiagnostic(state, stage, command, reason)
        attemptRejectedClose(state, command, tracked)
    end
    return nil, reason
end

local function acceptWorkImpl(state, commandValue)
    local constants, validation, identifiers = dependencies()
    local command, commandError = normalizeCommand(commandValue)
    if command == nil then
        return nil, commandError
    end
    local disposition, dispositionError = sequenceDisposition(state, command)
    if disposition == nil then
        return nil, dispositionError
    end

    local mutationOccurred = false
    local cycleValue, cycleReason = callLedger(
        state,
        "getOpenCycle",
        command.attribution.landKey
    )
    local cycle = nil
    local createdCycle = false
    if cycleValue ~= nil then
        cycle, cycleReason = normalizeCycleDto(
            cycleValue,
            command.attribution.landKey
        )
        if cycle == nil then
            return nil, cycleReason
        end
        local boundaryEvidence, boundaryEvidenceReason = callLedger(
            state, "getCycleBoundaryEvidence", cycle.id)
        if boundaryEvidence == nil then
            return nil, boundaryEvidenceReason
        end
        if type(boundaryEvidence) ~= "table"
            or type(rawget(boundaryEvidence, "hasHarvest")) ~= "boolean"
            or (boundaryEvidence.hasHarvest
                and (type(rawget(boundaryEvidence,
                    "lastHarvestMissionTime")) ~= "number"
                    or type(rawget(boundaryEvidence,
                        "lastHarvestRecordId")) ~= "string")) then
            return nil, "invalidLedgerResult"
        end
        local boundaryReason = automaticBoundaryReason(
            constants, cycle, command, boundaryEvidence, disposition)
        if boundaryReason ~= nil then
            local closed, closeReason
            if state.methods.closeCycles ~= nil then
                local closedCycles, closedSessions = callLedger(
                    state,
                    "closeCycles",
                    {
                        cycleIds = {cycle.id},
                        missionTime = command.missionTime,
                        period = command.period,
                        year = command.year,
                        reason = boundaryReason,
                        checkpointSessions = true
                    }
                )
                if closedCycles == nil then
                    return nil, closedSessions
                end
                if type(closedCycles) ~= "table"
                    or type(closedSessions) ~= "table"
                    or #closedCycles ~= 1 then
                    return nil, "invalidLedgerResult"
                end
                for _, sessionId in ipairs(closedSessions) do
                    if type(sessionId) ~= "string" then
                        return nil, "invalidLedgerResult"
                    end
                    clearSession(state, sessionId)
                end
                closed = closedCycles[1]
            else
                -- Compatibility for narrow injected ledgers. Production
                -- ledgers provide closeCycles so session checkpointing and
                -- cycle closure share one neutral-budget transaction.
                local checkpointed, checkpointReason = callLedger(
                    state,
                    "checkpointCycleSessions",
                    cycle.id,
                    boundaryReason,
                    command.missionTime
                )
                if checkpointed == nil then
                    return nil, checkpointReason
                end
                if type(checkpointed) ~= "table" then
                    return nil, "invalidLedgerResult"
                end
                for _, sessionId in ipairs(checkpointed) do
                    if type(sessionId) ~= "string" then
                        return nil, "invalidLedgerResult"
                    end
                    clearSession(state, sessionId)
                end
                closed, closeReason = callLedger(state, "closeCycle", {
                    cycleId = cycle.id,
                    missionTime = command.missionTime,
                    period = command.period,
                    year = command.year,
                    reason = boundaryReason
                })
            end
            if closed == nil then
                return nil, closeReason
            end
            if type(closed) ~= "table"
                or rawget(closed, "id") ~= cycle.id
                or rawget(closed, "state")
                    ~= constants.CYCLE_STATE.Closed
                or rawget(closed, "closeReason") ~= boundaryReason then
                return nil, "invalidLedgerResult"
            end
            cycle = nil
            cycleReason = "noOpenCycle"
            mutationOccurred = true
        end
    end
    if cycle ~= nil then
        if cycleDescriptorConflicts(cycle, command) then
            return nil, "cycleDescriptorMismatch"
        end
        if rawget(cycle, "fruitType") == "unknown"
            and command.fruitType ~= "unknown" then
            local promoted, promotedOrReason = callLedger(
                state,
                "promoteCycleDescriptor",
                {
                    cycleId = cycle.id,
                    fruitType = command.fruitType,
                    fruitTypeId = command.fruitTypeId,
                    fillTypeId = command.fillTypeId
                }
            )
            if promoted == nil then return nil, promotedOrReason end
            cycle, cycleReason = normalizeCycleDto(
                promoted, command.attribution.landKey)
            if cycle == nil then return nil, cycleReason end
            mutationOccurred = promotedOrReason == true
        end
        -- Recheck the detached result so a hostile or faulty Ledger proxy
        -- cannot return a descriptor different from the accepted evidence.
        if cycleDescriptorConflicts(cycle, command) then
            return nil, "cycleDescriptorMismatch"
        end
        if disposition == "same" and dispositionError.cycleId ~= cycle.id then
            return nil, "evidenceSequenceCollision"
        end
    elseif cycleReason ~= "noOpenCycle" then
        return nil, cycleReason
    elseif disposition == "same" then
        return nil, "evidenceSequenceCollision"
    end

    local observationId, observationError = callLedger(
        state,
        "createObservationId",
        command.rootVehicleId,
        command.serverSequence,
        command.observationDiscriminator
    )
    if observationId == nil then
        return nil, observationError
    end
    local observationParts = identifiers.parseObservationId(observationId)
    if observationParts == nil
        or observationParts.vehicleUniqueId ~= command.rootVehicleId
        or observationParts.sequence ~= command.serverSequence
        or observationParts.discriminator ~= command.observationDiscriminator then
        return nil, "invalidLedgerResult"
    end

    if cycle == nil then
        local opened = nil
        opened, cycleReason = callLedger(state, "openCycle", {
            landKey = command.attribution.landKey,
            fruitType = command.fruitType,
            fruitTypeId = command.fruitTypeId,
            fillTypeId = command.fillTypeId,
            period = command.period,
            missionTime = command.missionTime,
            year = command.year,
            cycleAreaHa = command.attribution.cycleAreaHa,
            qualityClass = command.qualityClass,
            reasons = command.reasons
        })
        if opened == nil then
            return nil, cycleReason
        end
        cycle, cycleReason = normalizeCycleDto(
            opened,
            command.attribution.landKey
        )
        if cycle == nil then
            addDiagnostic(state, "openCycle", command, cycleReason)
            return nil, cycleReason
        end
        createdCycle = true
        mutationOccurred = true
    end

    local session = nil
    local createdSession = false
    local createdEvidence = false
    local tracked = nil
    if disposition == "same" then
        session = dispositionError.session
        tracked = state.sessionsByRoot[command.rootVehicleId]
        -- This sequence already has accepted session evidence. A subsequent
        -- record-stage rejection is therefore post-evidence even though the
        -- current call correctly skips a second evidence mutation.
        mutationOccurred = true
    else
        local sessionValue, sessionCreatedOrReason = callLedger(
            state,
            "startSession",
            {
                evidence = true,
                cycleId = cycle.id,
                landKey = command.attribution.landKey,
                rootVehicleId = command.rootVehicleId,
                operationType = command.operationType,
                fillType = command.fillType,
                operatorKind = command.operatorKind,
                operatorId = command.operatorId,
                operatorQuality = command.operatorQuality,
                implementIds = command.implementIds,
                missionTime = command.missionTime,
                reasons = command.sessionReasons
            }
        )
        if sessionValue == nil then
            return rejectAfterStage(
                state,
                "startSession",
                command,
                sessionCreatedOrReason,
                mutationOccurred,
                nil
            )
        end
        local startCreated = sessionCreatedOrReason
        local normalizedSession, normalizeError = normalizeSessionDto(
            sessionValue,
            command,
            cycle.id
        )
        if normalizedSession == nil then
            return rejectAfterStage(
                state,
                "startSession",
                command,
                normalizeError,
                true,
                nil
            )
        end
        session = normalizedSession
        trackSession(state, command, session)
        tracked = state.sessionsByRoot[command.rootVehicleId]
        if type(startCreated) ~= "boolean" then
            return rejectAfterStage(
                state,
                "startSession",
                command,
                "invalidLedgerResult",
                true,
                tracked
            )
        end
        createdSession = startCreated
        mutationOccurred = true

        local evidenceValue, evidenceAcceptedOrReason = callLedger(
            state,
            "recordEvidence",
            {
                sessionId = session.id,
                serverSequence = command.serverSequence,
                activeMs = command.activeMs,
                missionTime = command.missionTime
            }
        )
        if evidenceValue == nil then
            return rejectAfterStage(
                state,
                "recordEvidence",
                command,
                evidenceAcceptedOrReason,
                mutationOccurred,
                tracked
            )
        end
        if type(evidenceAcceptedOrReason) ~= "boolean" then
            return rejectAfterStage(
                state,
                "recordEvidence",
                command,
                "invalidLedgerResult",
                mutationOccurred,
                tracked
            )
        end
        local evidenceSession, evidenceNormalizeError = normalizeSessionDto(
            evidenceValue,
            command,
            cycle.id
        )
        if evidenceSession == nil then
            return rejectAfterStage(
                state,
                "recordEvidence",
                command,
                evidenceNormalizeError,
                mutationOccurred,
                tracked
            )
        end
        session = evidenceSession
        createdEvidence = evidenceAcceptedOrReason
        trackSession(state, command, session)
        tracked = state.sessionsByRoot[command.rootVehicleId]
        state.lastSequenceByRoot[command.rootVehicleId] = command.serverSequence
        state.sequenceContextsByRoot[command.rootVehicleId] = {
            sequence = command.serverSequence,
            cycleId = cycle.id,
            landKey = command.attribution.landKey,
            attributionKind = command.attribution.kind,
            candidateLandKeys = command.attribution.kind == "mixed"
                and command.attribution.candidateLandKeys
                or nil,
            missionTime = command.missionTime,
            activeMs = command.activeMs,
            fillType = command.fillType,
            fillTypeId = command.fillTypeId,
            operatorKind = command.operatorKind,
            operatorId = command.operatorId,
            operatorQuality = command.operatorQuality,
            implementIds = command.implementIds,
            period = command.period,
            year = command.year,
            session = session,
            operationRecordIdsByDiscriminator = {}
        }
    end

    local recordValue, recordCreatedOrReason = callLedger(
        state,
        "acceptRecord",
        {
            cycleId = cycle.id,
            sessionId = session.id,
            recordType = constants.RECORD_TYPE.Operation,
            category = command.attribution.kind == "mixed"
                and "mixedBoundaryTick"
                or command.operationType,
            accountingClass = constants.ACCOUNTING_CLASS.Observed,
            qualityClass = command.qualityClass,
            amount = command.changedAreaHa,
            unit = constants.UNIT.Hectares,
            missionTime = command.missionTime,
            observationId = observationId,
            segmentKey = "work-" .. command.observationDiscriminator,
            reasons = command.reasons,
            metadata = makeMetadata(command),
            references = {}
        }
    )
    if recordValue == nil then
        return rejectAfterStage(
            state,
            "acceptRecord",
            command,
            recordCreatedOrReason,
            mutationOccurred,
            tracked
        )
    end
    if type(recordCreatedOrReason) ~= "boolean" then
        return rejectAfterStage(
            state,
            "acceptRecord",
            command,
            "invalidLedgerResult",
            mutationOccurred,
            tracked
        )
    end
    local record, recordNormalizeError = normalizeRecordDto(
        recordValue,
        command,
        cycle.id,
        session.id,
        observationId
    )
    if record == nil then
        return rejectAfterStage(
            state,
            "acceptRecord",
            command,
            recordNormalizeError,
            true,
            tracked
        )
    end

    local sequenceContext = state.sequenceContextsByRoot[command.rootVehicleId]
    if sequenceContext == nil
        or sequenceContext.sequence ~= command.serverSequence then
        return rejectAfterStage(
            state,
            "recordContext",
            command,
            "evidenceSequenceCollision",
            true,
            tracked
        )
    end
    local priorRecordId = sequenceContext.operationRecordIdsByDiscriminator[
        command.observationDiscriminator]
    if priorRecordId ~= nil and priorRecordId ~= record.id then
        return rejectAfterStage(
            state,
            "recordContext",
            command,
            "evidenceSequenceCollision",
            true,
            tracked
        )
    end
    sequenceContext.operationRecordIdsByDiscriminator[
        command.observationDiscriminator] = record.id

    local result, resultError = detachedCopy({
        cycle = cycle,
        session = session,
        record = record,
        attribution = command.attribution,
        created = {
            cycle = createdCycle,
            session = createdSession,
            evidence = createdEvidence,
            record = recordCreatedOrReason
        }
    })
    if result == nil then
        return rejectAfterStage(
            state,
            "result",
            command,
            resultError or "invalidLedgerResult",
            true,
            tracked
        )
    end
    return result
end

local function closeRejectedFactCarrier(state, fact, session, created)
    if created ~= true or session == nil then return end
    local closed = callLedger(state, "closeSession", {
        sessionId = session.id,
        reason = "recordRejected",
        endMissionTime = fact.missionTime
    })
    if closed == nil then
        addDiagnostic(state, "closeFactOnlyCarrier", fact, "ledgerRejected")
    end
end

local function acceptFactOnlyImpl(state, factValue)
    local constants, validation, identifiers = dependencies()
    local fact, factError = normalizeFactOnly(factValue)
    if fact == nil then return nil, factError end

    local cycleValue, cycleReason = callLedger(
        state, "getOpenCycle", fact.attribution.landKey)
    if cycleValue == nil then return nil, cycleReason end
    local cycle = nil
    cycle, cycleReason = normalizeCycleDto(
        cycleValue, fact.attribution.landKey)
    if cycle == nil then return nil, cycleReason end

    local observationId, observationError = callLedger(
        state, "createObservationId", fact.rootVehicleId,
        fact.serverSequence, fact.observationDiscriminator)
    if observationId == nil then return nil, observationError end
    local observationParts = identifiers.parseObservationId(observationId)
    if observationParts == nil
        or observationParts.vehicleUniqueId ~= fact.rootVehicleId
        or observationParts.sequence ~= fact.serverSequence
        or observationParts.discriminator ~= fact.observationDiscriminator then
        return nil, "invalidLedgerResult"
    end

    local sessionValue, sessionCreatedOrReason = callLedger(
        state, "startSession", {
            evidence = true,
            cycleId = cycle.id,
            landKey = fact.attribution.landKey,
            rootVehicleId = fact.rootVehicleId,
            operationType = fact.operationType,
            fillType = fact.metadata.fillName,
            carrierKind = fact.carrierKind,
            operatorKind = fact.operatorKind,
            operatorId = fact.operatorId,
            operatorQuality = fact.operatorQuality,
            implementIds = fact.implementIds,
            missionTime = fact.missionTime,
            reasons = fact.sessionReasons
        })
    if sessionValue == nil then return nil, sessionCreatedOrReason end
    if type(sessionCreatedOrReason) ~= "boolean" then
        return nil, "invalidLedgerResult"
    end
    local session, sessionError = normalizeSessionDto(
        sessionValue, fact, cycle.id)
    if session == nil then return nil, sessionError end

    local metadata = fact.metadata
    metadata.unallocatedKind = "zeroChangedApplication"
    metadata.carrierLandKey = fact.attribution.landKey
    metadata.areaEvidence = "zeroChanged"
    metadata.attributionKind = fact.attribution.kind
    metadata.observationDiscriminator = fact.observationDiscriminator
    metadata.serverSequence = fact.serverSequence

    local recordValue, recordCreatedOrReason = callLedger(
        state, "acceptRecord", {
            cycleId = cycle.id,
            sessionId = session.id,
            recordType = fact.recordType,
            category = fact.category,
            accountingClass = constants.ACCOUNTING_CLASS.Observed,
            qualityClass = fact.qualityClass,
            amount = fact.amount,
            unit = fact.unit,
            missionTime = fact.missionTime,
            observationId = observationId,
            segmentKey = "unallocated-" .. fact.observationDiscriminator,
            reasons = fact.reasons,
            metadata = metadata,
            references = {}
        })
    if recordValue == nil then
        addDiagnostic(state, "acceptFactOnly", fact, recordCreatedOrReason)
        closeRejectedFactCarrier(
            state, fact, session, sessionCreatedOrReason)
        return nil, recordCreatedOrReason
    end
    if type(recordCreatedOrReason) ~= "boolean" then
        return nil, "invalidLedgerResult"
    end
    local record, copyError = detachedCopy(recordValue)
    if record == nil or validateToken(
        validation, constants, rawget(record, "id"),
        constants.LIMITS.idBytes) == nil
        or rawget(record, "cycleId") ~= cycle.id
        or rawget(record, "sessionId") ~= session.id
        or rawget(record, "observationId") ~= observationId
        or rawget(record, "recordType") ~= fact.recordType
        or rawget(record, "category") ~= fact.category
        or rawget(record, "accountingClass")
            ~= constants.ACCOUNTING_CLASS.Observed
        or rawget(record, "qualityClass")
            ~= constants.QUALITY_CLASS.Partial
        or rawget(record, "amount") ~= fact.amount
        or rawget(record, "unit") ~= constants.UNIT.Litres then
        return nil, copyError or "invalidLedgerResult"
    end
    trackSession(state, fact, session)
    local result, resultError = detachedCopy({
        cycle = cycle,
        session = session,
        record = record,
        attribution = fact.attribution,
        created = {
            cycle = false,
            session = sessionCreatedOrReason,
            evidence = false,
            record = recordCreatedOrReason
        }
    })
    if result == nil then return nil, resultError or "invalidLedgerResult" end
    return result
end

local function acceptObservedFactImpl(state, factValue)
    local constants, validation, identifiers = dependencies()
    local fact, factError = normalizeObservedFact(factValue)
    if fact == nil then return nil, factError end
    local context = state.sequenceContextsByRoot[fact.rootVehicleId]
    local tracked = state.sessionsByRoot[fact.rootVehicleId]
    if context == nil or tracked == nil
        or context.sequence ~= fact.serverSequence
        or tracked.sessionId ~= context.session.id then
        return nil, "acceptedEvidenceRequired"
    end
    local operationRecordId = context.operationRecordIdsByDiscriminator[
        fact.operationObservationDiscriminator]
    if operationRecordId == nil then return nil, "acceptedOperationRequired" end

    local observationId, observationError = callLedger(
        state,
        "createObservationId",
        fact.rootVehicleId,
        fact.serverSequence,
        fact.observationDiscriminator
    )
    if observationId == nil then return nil, observationError end
    local observationParts = identifiers.parseObservationId(observationId)
    if observationParts == nil
        or observationParts.vehicleUniqueId ~= fact.rootVehicleId
        or observationParts.sequence ~= fact.serverSequence
        or observationParts.discriminator ~= fact.observationDiscriminator then
        return nil, "invalidLedgerResult"
    end

    local metadata = fact.metadata
    metadata.attributionKind = context.attributionKind
    metadata.observationDiscriminator = fact.observationDiscriminator
    metadata.operationObservationDiscriminator =
        fact.operationObservationDiscriminator
    metadata.serverSequence = fact.serverSequence
    local reasons = fact.reasons
    local quality = fact.qualityClass
    if context.attributionKind == "mixed" then
        metadata.candidateLandKeys = {}
        for index, candidate in ipairs(context.candidateLandKeys) do
            metadata.candidateLandKeys[index] = candidate
        end
        metadata.mixedBoundary = true
        reasons, factError = mergeReasons(
            constants, reasons, {"boundaryUnresolved"})
        if reasons == nil then return nil, factError end
        quality = lowerQuality(quality, constants.QUALITY_CLASS.Partial)
    end

    local recordValue, createdOrReason = callLedger(state, "acceptRecord", {
        cycleId = context.cycleId,
        sessionId = context.session.id,
        recordType = fact.recordType,
        category = fact.category,
        accountingClass = constants.ACCOUNTING_CLASS.Observed,
        qualityClass = quality,
        amount = fact.amount,
        unit = fact.unit,
        missionTime = context.missionTime,
        observationId = observationId,
        segmentKey = COALESCED_FACT_CATEGORIES[fact.category]
            and ("fact-" .. fact.observationDiscriminator) or nil,
        reasons = reasons,
        metadata = metadata,
        references = {operationRecordId}
    })
    if recordValue == nil then
        addDiagnostic(state, "acceptObservedFact", {
            rootVehicleId = fact.rootVehicleId,
            missionTime = context.missionTime
        }, createdOrReason)
        return nil, createdOrReason
    end
    if type(createdOrReason) ~= "boolean" then
        return nil, "invalidLedgerResult"
    end
    local copied, copyError = detachedCopy(recordValue)
    if copied == nil
        or rawget(copied, "cycleId") ~= context.cycleId
        or rawget(copied, "sessionId") ~= context.session.id
        or rawget(copied, "observationId") ~= observationId
        or rawget(copied, "recordType") ~= fact.recordType
        or rawget(copied, "category") ~= fact.category
        or rawget(copied, "accountingClass")
            ~= constants.ACCOUNTING_CLASS.Observed
        or rawget(copied, "amount") ~= fact.amount
        or rawget(copied, "unit") ~= fact.unit then
        return nil, copyError or "invalidLedgerResult"
    end
    if fact.recordType == constants.RECORD_TYPE.Harvest then
        context.harvestRecordId = copied.id
    end
    return copied, createdOrReason
end

local function normalizeClosedIds(value)
    local constants, validation, identifiers = dependencies()
    local accepted, arrayError = validation.array(
        value,
        constants.LIMITS.maxRecords
    )
    if accepted == nil then
        return nil, arrayError
    end
    local result = {}
    local seen = {}
    for _, candidate in ipairs(accepted) do
        local sessionId = validateToken(
            validation,
            constants,
            candidate,
            constants.LIMITS.idBytes
        )
        if sessionId == nil or seen[sessionId] then
            return nil, "invalidLedgerResult"
        end
        seen[sessionId] = true
        result[#result + 1] = sessionId
    end
    table.sort(result, function(left, right)
        return identifiers.compare(left, right) < 0
    end)
    return result
end

local function closeRootImpl(state, rootVehicleIdValue, reasonValue, missionTimeValue)
    local constants, validation = dependencies()
    local rootVehicleId, validationError = validateToken(
        validation,
        constants,
        rootVehicleIdValue,
        constants.LIMITS.idBytes
    )
    if rootVehicleId == nil then
        return nil, validationError
    end
    local reason = nil
    reason, validationError = validateToken(
        validation,
        constants,
        reasonValue
    )
    if reason == nil then
        return nil, validationError
    end
    local missionTime = nil
    missionTime, validationError = validation.number(
        missionTimeValue,
        0,
        constants.LIMITS.maxMissionTime
    )
    if missionTime == nil then
        return nil, validationError
    end
    local tracked = state.sessionsByRoot[rootVehicleId]
    if tracked == nil then
        return {
            rootVehicleId = rootVehicleId,
            closed = false
        }
    end
    if missionTime < tracked.lastEvidenceTime then
        return nil, "timeBeforeLastEvidence"
    end
    local closedValue, closedOrReason = callLedger(state, "closeSession", {
        sessionId = tracked.sessionId,
        reason = reason,
        endMissionTime = missionTime
    })
    if closedValue == nil then
        return nil, closedOrReason
    end
    if type(closedOrReason) ~= "boolean" then
        return nil, "invalidLedgerResult"
    end
    local result = {
        rootVehicleId = rootVehicleId,
        sessionId = tracked.sessionId,
        closed = closedOrReason
    }
    clearRoot(state, rootVehicleId)
    return result
end

local function expireImpl(state, missionTimeValue)
    local constants, validation = dependencies()
    local missionTime, validationError = validation.number(
        missionTimeValue,
        0,
        constants.LIMITS.maxMissionTime
    )
    if missionTime == nil then
        return nil, validationError
    end
    local closedValue, closedReason = callLedger(
        state,
        "expireSessions",
        missionTime
    )
    if closedValue == nil then
        return nil, closedReason
    end
    local closed, normalizeError = normalizeClosedIds(closedValue)
    if closed == nil then
        return nil, normalizeError
    end
    for _, sessionId in ipairs(closed) do
        clearSession(state, sessionId)
    end
    return closed
end

local function checkpointImpl(state, reasonValue, missionTimeValue)
    local constants, validation = dependencies()
    local reason, validationError = validateToken(
        validation,
        constants,
        reasonValue
    )
    if reason == nil then
        return nil, validationError
    end
    local missionTime = nil
    missionTime, validationError = validation.number(
        missionTimeValue,
        0,
        constants.LIMITS.maxMissionTime
    )
    if missionTime == nil then
        return nil, validationError
    end
    local closedValue, closedReason = callLedger(
        state,
        "checkpointSessions",
        reason,
        missionTime
    )
    if closedValue == nil then
        return nil, closedReason
    end
    local closed, normalizeError = normalizeClosedIds(closedValue)
    if closed == nil then
        return nil, normalizeError
    end
    local roots = {}
    for rootVehicleId in pairs(state.sessionsByRoot) do
        roots[#roots + 1] = rootVehicleId
    end
    for _, rootVehicleId in ipairs(roots) do
        clearRoot(state, rootVehicleId)
    end
    return closed
end

local function ownershipChangedImpl(
    state,
    farmlandIdValue,
    oldFarmIdValue,
    newFarmIdValue,
    missionTimeValue
)
    local constants, validation = dependencies()
    local farmlandId, validationError = validation.integer(
        farmlandIdValue,
        1,
        constants.LIMITS.maxIdentifier
    )
    if farmlandId == nil then
        return nil, validationError
    end
    local oldFarmId = nil
    oldFarmId, validationError = validation.integer(
        oldFarmIdValue,
        1,
        constants.LIMITS.maxIdentifier
    )
    if oldFarmId == nil then
        return nil, validationError
    end
    local newFarmId = nil
    newFarmId, validationError = validation.integer(
        newFarmIdValue,
        1,
        constants.LIMITS.maxIdentifier
    )
    if newFarmId == nil then
        return nil, validationError
    end
    if newFarmId == oldFarmId then
        return nil, "invalidOwnershipChange"
    end
    local missionTime = nil
    missionTime, validationError = validation.number(
        missionTimeValue,
        0,
        constants.LIMITS.maxMissionTime
    )
    if missionTime == nil then
        return nil, validationError
    end
    local roots = {}
    for rootVehicleId, tracked in pairs(state.sessionsByRoot) do
        if tracked.farmId == oldFarmId
            and tracked.candidateFarmlands[farmlandId] == true then
            if missionTime < tracked.lastEvidenceTime then
                return nil, "timeBeforeLastEvidence"
            end
            roots[#roots + 1] = rootVehicleId
        end
    end
    table.sort(roots, byteLess)
    local closed = {}
    for _, rootVehicleId in ipairs(roots) do
        local tracked = state.sessionsByRoot[rootVehicleId]
        local closedValue, closedOrReason = callLedger(state, "closeSession", {
            sessionId = tracked.sessionId,
            reason = "ownershipChanged",
            endMissionTime = missionTime
        })
        if closedValue == nil then
            return nil, closedOrReason
        end
        if type(closedOrReason) ~= "boolean" then
            return nil, "invalidLedgerResult"
        end
        if closedOrReason then
            closed[#closed + 1] = tracked.sessionId
        end
        clearRoot(state, rootVehicleId)
    end
    return closed
end

local function diagnosticsImpl(state)
    return detachedCopy({
        rows = state.diagnostics,
        omittedCount = state.omittedDiagnostics
    })
end

local function closeCyclesImpl(state, command)
    if type(command) ~= "table" or getmetatable(command) ~= nil then
        return nil, "invalidCommand"
    end
    local requested = detachedCopy(command)
    if requested == nil then
        return nil, "invalidCommand"
    end
    requested.checkpointSessions = true
    local closedCycles, closedSessionsOrReason =
        callLedger(state, "closeCycles", requested)
    if closedCycles == nil then
        return nil, closedSessionsOrReason
    end
    if type(closedCycles) ~= "table" or getmetatable(closedCycles) ~= nil then
        return nil, "invalidLedgerResult"
    end
    local closedSessions, normalizeError =
        normalizeClosedIds(closedSessionsOrReason)
    if closedSessions == nil then
        return nil, normalizeError
    end
    for _, sessionId in ipairs(closedSessions) do
        clearSession(state, sessionId)
    end
    return {
        closedCycles = closedCycles,
        closedSessions = closedSessions
    }
end

function OperationCoordinator.new(ledger, ...)
    if select("#", ...) ~= 0 then
        return nil, "unexpectedArgument"
    end
    local constants, _, _, dependencyError = dependencies()
    if constants == nil then
        return nil, dependencyError
    end
    if type(ledger) ~= "table" then
        return nil, "invalidLedger"
    end
    local methods = {}
    for _, name in ipairs(LEDGER_METHODS) do
        local method = safeMethod(ledger, name)
        if method == nil then
            return nil, "invalidLedger"
        end
        methods[name] = method
    end
    local closeCyclesMethod = safeMethod(ledger, "closeCycles")
    if closeCyclesMethod ~= nil then
        methods.closeCycles = closeCyclesMethod
    end
    local coordinator = setmetatable({}, OperationCoordinator)
    PRIVATE[coordinator] = {
        ledger = ledger,
        methods = methods,
        diagnostics = {},
        omittedDiagnostics = 0,
        sessionsByRoot = {},
        rootBySession = {},
        sequenceContextsByRoot = {},
        lastSequenceByRoot = {}
    }
    return coordinator
end

local function guarded(self, implementation, ...)
    local state = PRIVATE[self]
    if state == nil then
        return nil, "invalidCoordinator"
    end
    local ok, first, second, third = pcall(implementation, state, ...)
    if not ok then
        return nil, "coordinatorInternalError"
    end
    return first, second, third
end

function OperationCoordinator.acceptWork(self, command, ...)
    if select("#", ...) ~= 0 then
        return nil, "unexpectedArgument"
    end
    return guarded(self, acceptWorkImpl, command)
end

function OperationCoordinator.acceptObservedFact(self, fact, ...)
    if select("#", ...) ~= 0 then
        return nil, "unexpectedArgument"
    end
    return guarded(self, acceptObservedFactImpl, fact)
end

function OperationCoordinator.acceptFactOnly(self, fact, ...)
    if select("#", ...) ~= 0 then
        return nil, "unexpectedArgument"
    end
    return guarded(self, acceptFactOnlyImpl, fact)
end

function OperationCoordinator.expire(self, missionTime, ...)
    if select("#", ...) ~= 0 then
        return nil, "unexpectedArgument"
    end
    return guarded(self, expireImpl, missionTime)
end

function OperationCoordinator.closeRoot(
    self,
    rootVehicleId,
    reason,
    missionTime,
    ...
)
    if select("#", ...) ~= 0 then
        return nil, "unexpectedArgument"
    end
    return guarded(
        self,
        closeRootImpl,
        rootVehicleId,
        reason,
        missionTime
    )
end

function OperationCoordinator.checkpoint(self, reason, missionTime, ...)
    if select("#", ...) ~= 0 then
        return nil, "unexpectedArgument"
    end
    return guarded(self, checkpointImpl, reason, missionTime)
end

function OperationCoordinator.closeCycles(self, command, ...)
    if select("#", ...) ~= 0 then
        return nil, "unexpectedArgument"
    end
    return guarded(self, closeCyclesImpl, command)
end

function OperationCoordinator.onOwnershipChanged(
    self,
    farmlandId,
    oldFarmId,
    newFarmId,
    missionTime,
    ...
)
    if select("#", ...) ~= 0 then
        return nil, "unexpectedArgument"
    end
    return guarded(
        self,
        ownershipChangedImpl,
        farmlandId,
        oldFarmId,
        newFarmId,
        missionTime
    )
end

function OperationCoordinator.getDiagnostics(self, ...)
    if select("#", ...) ~= 0 then
        return nil, "unexpectedArgument"
    end
    return guarded(self, diagnosticsImpl)
end

FieldProfitabilityLedger.Core.OperationCoordinator = OperationCoordinator

return OperationCoordinator
