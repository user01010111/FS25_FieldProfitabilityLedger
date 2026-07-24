-- Single-player adapter for complete, already-sealed WorkArea updates.
--
-- The engine-facing collector is injected by the runtime bootstrap.  It must
-- return every row for one root/update; this module performs all validation
-- and attribution before making the first coordinator call.

FieldProfitabilityLedger = FieldProfitabilityLedger or {}
FieldProfitabilityLedger.Adapters = FieldProfitabilityLedger.Adapters or {}

local WorkAreaAdapter = {}

local MAX_ROWS = 128
local MAX_DIAGNOSTICS = 32
local MAX_ROOTS = 128
local DISABLE_AFTER = 3
local OPERATION_DISCRIMINATORS = {
    plowing="o01", subsoiling="o02", cultivating="o03",
    discHarrowing="o04", powerHarrowing="o05", mulching="o06",
    stonePicking="o07", seedingPlanting="o08", rolling="o09",
    mechanicalWeeding="o0a", fertilizer="o0b", lime="o0c",
    herbicide="o0d", manure="o0e", slurry="o0f", digestate="o10",
    ordinaryArableHarvest="o11"
}

local UPDATE_KEYS = {
    activeMs = true, complete = true, fillType = true, fillTypeId = true,
    factOnly = true,
    fruitType = true, fruitTypeId = true, implementIds = true,
    missionTime = true, operatorId = true, operatorKind = true,
    operatorQuality = true, period = true, qualityClass = true,
    reasons = true, rootVehicleId = true, rows = true,
    serverSequence = true, year = true
}

local FACT_ONLY_KEYS = {
    amount = true, attribution = true, category = true, metadata = true,
    observationDiscriminator = true, operationType = true,
    qualityClass = true, reasons = true, recordType = true, unit = true
}

local FACT_METADATA_KEYS = {
    compatibilityProfile = true, consumerCount = true, fillName = true,
    fillTypeId = true, sourceCount = true
}

local FACT_ATTRIBUTION_KEYS = {
    baseField = {
        cycleAreaHa = true, farmId = true, farmlandId = true,
        fieldId = true, fieldKind = true, kind = true, landKey = true,
        qualityClass = true, reasons = true
    },
    parcel = {
        farmId = true, farmlandId = true, fieldKind = true, kind = true,
        landKey = true, qualityClass = true, reasons = true
    }
}

local APPLICATION_OPERATION = {
    seed = "seedingPlanting", fertilizer = "fertilizer", lime = "lime",
    herbicide = "herbicide", manure = "manure", slurry = "slurry",
    digestate = "digestate"
}

local ROW_KEYS = {
    attributionSnapshot = true, changedAreaHa = true,
    observationDiscriminator = true, operationType = true,
    workAreaType = true
}

local active = nil

local function finite(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function plain(value)
    return type(value) == "table" and getmetatable(value) == nil
end

local function closed(value, allowed)
    if not plain(value) then
        return false
    end
    local maximum = 0
    for _ in pairs(allowed) do
        maximum = maximum + 1
    end
    local count = 0
    for key in next, value do
        count = count + 1
        if count > maximum or type(key) ~= "string" or allowed[key] ~= true then
            return false
        end
    end
    return true
end

local function denseArray(value, maximum)
    if not plain(value) then
        return nil
    end
    local count = 0
    for key in next, value do
        if not finite(key) or key ~= math.floor(key) or key < 1
            or key > maximum then
            return nil
        end
        count = count + 1
    end
    for index = 1, count do
        if rawget(value, index) == nil then
            return nil
        end
    end
    return count
end

local function token(value, maximum)
    if type(value) ~= "string" or #value == 0 or #value > maximum then
        return nil
    end
    for index = 1, #value do
        local byte = string.byte(value, index)
        if byte < 33 or byte > 126 then
            return nil
        end
    end
    return value
end

local function byteLess(left, right)
    local count = math.min(#left, #right)
    for index = 1, count do
        local a, b = string.byte(left, index), string.byte(right, index)
        if a ~= b then
            return a < b
        end
    end
    return #left < #right
end

local function integer(value, minimum, maximum)
    if not finite(value) or value ~= math.floor(value)
        or value < minimum or value > maximum then
        return nil
    end
    return value
end

local function dependencies()
    local root = FieldProfitabilityLedger
    local core = type(root) == "table" and rawget(root, "Core") or nil
    local constants = type(core) == "table" and rawget(core, "Constants") or nil
    local exact = type(core) == "table" and rawget(core, "ExactSum") or nil
    local identifiers = type(core) == "table"
        and rawget(core, "Identifiers") or nil
    local attribution = type(core) == "table" and rawget(core, "FieldAttribution") or nil
    if not plain(core) or not plain(constants) or not plain(constants.LIMITS)
        or not plain(constants.OPERATION)
        or not plain(constants.QUALITY_CLASS_SET)
        or not plain(exact) or type(exact.new) ~= "function"
        or type(exact.add) ~= "function" or type(exact.finish) ~= "function"
        or not plain(identifiers)
        or type(identifiers.parseLandKey) ~= "function"
        or not plain(attribution) or type(attribution.resolve) ~= "function" then
        return nil, "coreDependencyUnavailable"
    end
    return {
        constants = constants,
        exact = exact,
        identifiers = identifiers,
        attribution = attribution
    }
end

local function primitiveContext(context)
    local result = {}
    if plain(context) then
        for key, value in next, context do
            if type(key) == "string"
                and (type(value) == "string" or type(value) == "number"
                    or type(value) == "boolean") then
                result[key] = value
            end
        end
    end
    return result
end

local function diagnose(state, code, category, context)
    local row = {
        category = category,
        code = code,
        context = primitiveContext(context)
    }
    if #state.diagnostics < MAX_DIAGNOSTICS then
        state.diagnostics[#state.diagnostics + 1] = row
    else
        state.omittedDiagnostics = state.omittedDiagnostics + 1
    end
    local port = rawget(state.runtime, "diagnose")
    if type(port) == "function" then
        pcall(port, code, category, row.context)
    end
end

local function contractFailure(state, code, context)
    state.consecutiveErrors = math.min(DISABLE_AFTER, state.consecutiveErrors + 1)
    diagnose(state, code, "workArea", context)
    if state.consecutiveErrors >= DISABLE_AFTER then
        state.disabled = true
        diagnose(state, "categoryDisabled", "workArea", context)
    end
end

local function rejection(state, code, context)
    diagnose(state, code, "workArea", context)
    return nil, code
end

local function copyStringArray(value, maximum, tokenBytes)
    local count = denseArray(value, maximum)
    if count == nil then
        return nil
    end
    local result, seen = {}, {}
    for index = 1, count do
        local item = token(rawget(value, index), tokenBytes)
        if item == nil or seen[item] then
            return nil
        end
        seen[item] = true
        result[#result + 1] = item
    end
    table.sort(result, byteLess)
    return result
end

local function copyReasons(value, limits)
    return copyStringArray(value, limits.maxReasons, limits.tokenBytes)
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

local function attributionIdentity(value)
    local function numberText(candidate)
        return candidate == nil and "" or string.format("%.17g", candidate)
    end
    local parts = {
        value.kind, value.landKey, numberText(value.farmId),
        numberText(value.farmlandId), numberText(value.fieldId),
        tostring(value.fieldKind or ""), numberText(value.cycleAreaHa),
        value.qualityClass
    }
    for _, reason in ipairs(value.reasons or {}) do
        parts[#parts + 1] = reason
    end
    if value.kind == "mixed" then
        local candidates = value.candidateLandKeys
        local count = denseArray(candidates, 16)
        if count == nil then return nil end
        parts[#parts + 1] = "mixedCandidates"
        parts[#parts + 1] = tostring(count)
        for index = 1, count do
            local candidate = token(candidates[index], 64)
            if candidate == nil then return nil end
            parts[#parts + 1] = candidate
        end
    end
    return table.concat(parts, "\31")
end

local function appendSharedFingerprint(target, shared)
    local function add(value)
        target[#target + 1] = value == nil and "" or tostring(value)
    end
    local function addNumber(value)
        target[#target + 1] = value == nil and ""
            or string.format("%.17g", value)
    end
    add(shared.rootVehicleId)
    addNumber(shared.serverSequence)
    addNumber(shared.missionTime)
    addNumber(shared.activeMs)
    addNumber(shared.period)
    addNumber(shared.year)
    add(shared.fruitType)
    addNumber(shared.fruitTypeId)
    add(shared.fillType)
    addNumber(shared.fillTypeId)
    add(shared.operatorKind)
    add(shared.operatorId)
    add(shared.operatorQuality)
    add(shared.qualityClass)
    for _, value in ipairs(shared.implementIds) do add(value) end
    target[#target + 1] = "\29"
    for _, value in ipairs(shared.reasons) do add(value) end
end

local function resolveAttribution(deps, snapshot)
    local ok, value, reason, extra = pcall(deps.attribution.resolve, snapshot)
    if not ok then
        return nil, "attributionCallFailed", true
    end
    if extra ~= nil then
        return nil, "attributionContractViolation", true
    end
    if value == nil then
        return nil, type(reason) == "string" and reason or "attributionRejected", false
    end
    local kind = plain(value) and rawget(value, "kind") or nil
    if reason ~= nil or not plain(value)
        or (kind ~= "baseField" and kind ~= "parcel" and kind ~= "mixed") then
        return nil, "attributionContractViolation", true
    end
    return value
end

local function validateShared(update, deps)
    local limits = deps.constants.LIMITS
    if not closed(update, UPDATE_KEYS) or update.complete ~= true then
        return nil, "incompleteUpdate"
    end
    local root = token(update.rootVehicleId, limits.idBytes)
    local implements = copyStringArray(
        update.implementIds, limits.maxReferences, limits.idBytes
    )
    local reasons = copyReasons(update.reasons, limits)
    if root == nil or implements == nil or reasons == nil then
        return nil, "invalidUpdateContext"
    end
    local missionTime = finite(update.missionTime)
        and update.missionTime >= 0 and update.missionTime <= limits.maxMissionTime
    local sequence = integer(update.serverSequence, 1, limits.maxIdentifier)
    local activeMs = finite(update.activeMs) and update.activeMs >= 0
        and update.activeMs <= limits.maxDurationMs
    local period = integer(update.period, 1, limits.maxPeriod)
    local year = update.year
    if year ~= nil then year = integer(year, 0, limits.maxYear) end
    local fruit = token(update.fruitType, limits.tokenBytes)
    local fruitId = update.fruitTypeId
    if fruitId ~= nil then
        fruitId = integer(fruitId, 0, limits.maxIdentifier)
    end
    local fill = update.fillType
    if fill ~= nil then fill = token(fill, limits.tokenBytes) end
    local fillId = update.fillTypeId
    if fillId ~= nil then
        fillId = integer(fillId, 0, limits.maxIdentifier)
    end
    local operatorKind = update.operatorKind
    local operatorId = update.operatorId
    if operatorId ~= nil then operatorId = token(operatorId, limits.idBytes) end
    local operatorQuality = update.operatorQuality
    local quality = update.qualityClass
    if not missionTime or sequence == nil or not activeMs or period == nil
        or (update.year ~= nil and year == nil)
        or fruit == nil or (update.fruitTypeId ~= nil and fruitId == nil)
        or (update.fillType ~= nil and fill == nil)
        or (update.fillTypeId ~= nil and fillId == nil)
        or (update.operatorId ~= nil and operatorId == nil)
        or (operatorKind ~= "player" and operatorKind ~= "ai"
            and operatorKind ~= "unknown")
        or deps.constants.QUALITY_CLASS_SET[operatorQuality] ~= true
        or (quality ~= "Complete" and quality ~= "Partial")
        or (quality ~= "Complete" and #reasons == 0)
        or (operatorKind == "unknown" and (update.operatorId ~= nil
            or operatorQuality == "Complete")) then
        return nil, "invalidUpdateContext"
    end
    local rowCount = denseArray(update.rows, MAX_ROWS)
    if rowCount == nil then
        return nil, "invalidRowTopology"
    end
    return {
        rootVehicleId = root, implementIds = implements,
        missionTime = update.missionTime, serverSequence = sequence,
        activeMs = update.activeMs, period = period, year = update.year,
        fruitType = fruit, fruitTypeId = fruitId,
        fillType = fill, fillTypeId = fillId,
        operatorKind = operatorKind, operatorId = operatorId,
        operatorQuality = operatorQuality, qualityClass = quality,
        reasons = reasons, rowCount = rowCount
    }
end

local function validateFactAttribution(value, deps, parcelFallbackEnabled)
    local limits = deps.constants.LIMITS
    local kind = plain(value) and rawget(value, "kind") or nil
    local allowed = FACT_ATTRIBUTION_KEYS[kind]
    if allowed == nil or not closed(value, allowed) then
        return nil, "invalidFactOnlyAttribution"
    end
    if kind == "parcel" and not parcelFallbackEnabled then
        return nil, "parcelFallbackDisabled"
    end
    local landKey = token(value.landKey, limits.idBytes)
    local land = landKey ~= nil and deps.identifiers.parseLandKey(landKey) or nil
    local farmId = integer(value.farmId, 1, limits.maxIdentifier)
    local farmlandId = integer(value.farmlandId, 1, limits.maxIdentifier)
    local reasonCount = denseArray(value.reasons, limits.maxReasons)
    if land == nil or farmId == nil or farmlandId == nil
        or reasonCount == nil or land.farmId ~= farmId
        or land.farmlandId ~= farmlandId then
        return nil, "invalidFactOnlyAttribution"
    end
    local reasons = {}
    for index = 1, reasonCount do
        reasons[index] = token(value.reasons[index], limits.tokenBytes)
        if reasons[index] == nil then
            return nil, "invalidFactOnlyAttribution"
        end
    end
    if kind == "baseField" then
        local fieldId = integer(value.fieldId, 1, limits.maxIdentifier)
        local area = value.cycleAreaHa
        if area ~= nil and (not finite(area) or area <= 0
            or area > limits.maxAreaHa) then
            return nil, "invalidFactOnlyAttribution"
        end
        if fieldId == nil or land.fieldKind ~= "base"
            or land.fieldId ~= fieldId or value.fieldKind ~= "base"
            or value.qualityClass ~= "Complete" or reasonCount ~= 0 then
            return nil, "invalidFactOnlyAttribution"
        end
        return {
            kind = kind, landKey = landKey, farmId = farmId,
            farmlandId = farmlandId, fieldId = fieldId, fieldKind = "base",
            cycleAreaHa = area, qualityClass = "Complete", reasons = reasons
        }
    end
    local ordinaryParcel = reasonCount == 1 and reasons[1] == "parcelFallback"
    local customParcel = reasonCount == 2
        and reasons[1] == "customFieldGeometry"
        and reasons[2] == "parcelFallback"
    if land.fieldKind ~= "parcel" or value.fieldKind ~= "parcel"
        or value.qualityClass ~= "Partial"
        or (not ordinaryParcel and not customParcel) then
        return nil, "invalidFactOnlyAttribution"
    end
    return {
        kind = kind, landKey = landKey, farmId = farmId,
        farmlandId = farmlandId, fieldKind = "parcel",
        qualityClass = "Partial", reasons = reasons
    }
end

local function validateFactOnly(value, deps, parcelFallbackEnabled)
    local limits = deps.constants.LIMITS
    if not closed(value, FACT_ONLY_KEYS) then
        return nil, "invalidFactOnly"
    end
    local attribution, reason = validateFactAttribution(
        value.attribution, deps, parcelFallbackEnabled)
    if attribution == nil then return nil, reason end
    local category = token(value.category, limits.tokenBytes)
    local expectedOperation = category ~= nil
        and APPLICATION_OPERATION[category] or nil
    local operation = token(value.operationType, limits.tokenBytes)
    local discriminator = token(
        value.observationDiscriminator, limits.idBytes)
    local reasonCount = denseArray(value.reasons, limits.maxReasons)
    local metadata = value.metadata
    if value.recordType ~= "input" or value.unit ~= "litres"
        or value.qualityClass ~= "Partial" or expectedOperation == nil
        or operation ~= expectedOperation or discriminator == nil
        or not finite(value.amount) or value.amount <= 0
        or value.amount > limits.maxPhysical
        or reasonCount ~= 1 or value.reasons[1] ~= "zeroChangedArea"
        or not closed(metadata, FACT_METADATA_KEYS) then
        return nil, "invalidFactOnly"
    end
    local profile = token(metadata.compatibilityProfile, limits.textBytes)
    local fillName = token(metadata.fillName, limits.textBytes)
    local consumerCount = integer(
        metadata.consumerCount, 1, limits.maxReferences)
    local sourceCount = integer(metadata.sourceCount, 1, limits.maxReferences)
    local fillTypeId = metadata.fillTypeId
    if fillTypeId ~= nil then
        fillTypeId = integer(fillTypeId, 0, limits.maxIdentifier)
    end
    if profile == nil or fillName == nil or consumerCount == nil
        or sourceCount == nil
        or (metadata.fillTypeId ~= nil and fillTypeId == nil) then
        return nil, "invalidFactOnly"
    end
    return {
        attribution = attribution,
        observationDiscriminator = discriminator,
        operationType = operation,
        recordType = "input", category = category, amount = value.amount,
        unit = "litres", qualityClass = "Partial",
        reasons = {"zeroChangedArea"},
        metadata = {
            compatibilityProfile = profile,
            consumerCount = consumerCount,
            fillName = fillName,
            fillTypeId = fillTypeId,
            sourceCount = sourceCount
        }
    }
end

local function combinedDiscriminator(operationType, discriminators, limit)
    table.sort(discriminators, byteLess)
    -- Root and server sequence are already canonical observation-ID fields.
    -- The operation token distinguishes the compatible same-sequence groups;
    -- raw row identities remain in the replay fingerprint below.
    local value = OPERATION_DISCRIMINATORS[operationType]
    if value == nil then
        return nil, "unsupportedWorkAreaCategory"
    end
    if token(value, limit) == nil then
        return nil, "combinedDiscriminatorTooLong"
    end
    return value
end

local function prepare(update, deps, parcelFallbackEnabled)
    local shared, reason = validateShared(update, deps)
    if shared == nil then
        return nil, reason, true
    end
    local limits = deps.constants.LIMITS
    local groups, groupOrder = {}, {}
    local attributionKey, attributionValue = nil, nil
    local positiveCount = 0
    local factOnly = nil
    if rawget(update, "factOnly") ~= nil then
        factOnly, reason = validateFactOnly(
            update.factOnly, deps, parcelFallbackEnabled)
        if factOnly == nil then return nil, reason, false end
    end
    for index = 1, shared.rowCount do
        local row = rawget(update.rows, index)
        if not closed(row, ROW_KEYS) or type(row.workAreaType) ~= "string"
            or not finite(row.changedAreaHa) or row.changedAreaHa < 0
            or row.changedAreaHa > limits.maxAreaHa then
            return nil, "invalidWorkAreaRow", true
        end
        if row.changedAreaHa > 0 and string.lower(row.workAreaType) ~= "auxiliary" then
            positiveCount = positiveCount + 1
            local operation = token(row.operationType, limits.tokenBytes)
            local discriminator = token(
                row.observationDiscriminator, limits.idBytes
            )
            if operation == nil or deps.constants.OPERATION[operation] ~= true
                or discriminator == nil then
                return nil, "unsupportedWorkAreaCategory", false
            end
            local attribution, attributionReason, contractError =
                resolveAttribution(deps, row.attributionSnapshot)
            if attribution == nil then
                return nil, attributionReason, contractError
            end
            if attribution.kind == "parcel" and not parcelFallbackEnabled then
                return nil, "parcelFallbackDisabled", false
            end
            local identity = attributionIdentity(attribution)
            if identity == nil then
                return nil, "attributionContractViolation", true
            end
            if attributionKey == nil then
                attributionKey, attributionValue = identity, attribution
            elseif attributionKey ~= identity then
                return nil, "distinctLandOrAttributionContext", false
            end
            local group = groups[operation]
            if group == nil then
                local accumulator, sumReason = deps.exact.new(
                    limits.maxAreaHa, MAX_ROWS
                )
                if accumulator == nil then
                    return nil, sumReason or "exactSumUnavailable", true
                end
                group = {sum = accumulator, discriminators = {}, seen = {}}
                groups[operation] = group
                groupOrder[#groupOrder + 1] = operation
            end
            if group.seen[discriminator] then
                return nil, "duplicateWorkAreaRow", false
            end
            group.seen[discriminator] = true
            group.discriminators[#group.discriminators + 1] = discriminator
            local added, sumReason = deps.exact.add(group.sum, row.changedAreaHa)
            if added == nil then
                return nil, sumReason or "exactSumRejected", true
            end
        end
    end
    if factOnly ~= nil and positiveCount > 0 then
        return nil, "factOnlyWithPositiveRows", false
    end
    if positiveCount == 0 then
        if factOnly ~= nil then
            local fingerprint = {}
            appendSharedFingerprint(fingerprint, shared)
            fingerprint[#fingerprint + 1] = "factOnly"
            fingerprint[#fingerprint + 1] = attributionIdentity(
                factOnly.attribution)
            fingerprint[#fingerprint + 1] = factOnly.recordType
            fingerprint[#fingerprint + 1] = factOnly.category
            fingerprint[#fingerprint + 1] = factOnly.operationType
            fingerprint[#fingerprint + 1] = factOnly.observationDiscriminator
            fingerprint[#fingerprint + 1] = string.format(
                "%.17g", factOnly.amount)
            fingerprint[#fingerprint + 1] = factOnly.unit
            fingerprint[#fingerprint + 1] = factOnly.qualityClass
            fingerprint[#fingerprint + 1] = factOnly.reasons[1]
            local metadata = factOnly.metadata
            fingerprint[#fingerprint + 1] = metadata.compatibilityProfile
            fingerprint[#fingerprint + 1] = tostring(metadata.consumerCount)
            fingerprint[#fingerprint + 1] = metadata.fillName
            fingerprint[#fingerprint + 1] = metadata.fillTypeId == nil and ""
                or tostring(metadata.fillTypeId)
            fingerprint[#fingerprint + 1] = tostring(metadata.sourceCount)
            return {
                commands = {},
                factOnly = {
                    activeMs = shared.activeMs,
                    attribution = factOnly.attribution,
                    implementIds = shared.implementIds,
                    missionTime = shared.missionTime,
                    observationDiscriminator =
                        factOnly.observationDiscriminator,
                    operationType = factOnly.operationType,
                    operatorId = shared.operatorId,
                    operatorKind = shared.operatorKind,
                    operatorQuality = shared.operatorQuality,
                    rootVehicleId = shared.rootVehicleId,
                    serverSequence = shared.serverSequence,
                    recordType = factOnly.recordType,
                    category = factOnly.category,
                    amount = factOnly.amount,
                    unit = factOnly.unit,
                    qualityClass = factOnly.qualityClass,
                    reasons = factOnly.reasons,
                    metadata = factOnly.metadata
                },
                fingerprint = table.concat(fingerprint, "\30"),
                shared = shared
            }
        end
        return {commands = {}, fingerprint = "zero"}
    end
    table.sort(groupOrder, byteLess)
    local commands, fingerprint = {}, {}
    appendSharedFingerprint(fingerprint, shared)
    fingerprint[#fingerprint + 1] = attributionKey
    for _, operation in ipairs(groupOrder) do
        local group = groups[operation]
        local area, sumReason = deps.exact.finish(group.sum, limits.maxAreaHa)
        if area == nil or area <= 0 then
            return nil, sumReason or "invalidExactArea", true
        end
        local discriminator, discriminatorReason = combinedDiscriminator(
            operation, group.discriminators, limits.idBytes
        )
        if discriminator == nil then
            return nil, discriminatorReason, false
        end
        commands[#commands + 1] = {
            attribution = attributionValue,
            operationType = operation,
            changedAreaHa = area,
            rootVehicleId = shared.rootVehicleId,
            implementIds = shared.implementIds,
            missionTime = shared.missionTime,
            serverSequence = shared.serverSequence,
            activeMs = shared.activeMs,
            observationDiscriminator = discriminator,
            period = shared.period, year = shared.year,
            fruitType = shared.fruitType, fruitTypeId = shared.fruitTypeId,
            fillType = shared.fillType, fillTypeId = shared.fillTypeId,
            operatorKind = shared.operatorKind, operatorId = shared.operatorId,
            operatorQuality = shared.operatorQuality,
            qualityClass = shared.qualityClass, reasons = shared.reasons
        }
        fingerprint[#fingerprint + 1] = operation
        fingerprint[#fingerprint + 1] = string.format("%.17g", area)
        fingerprint[#fingerprint + 1] = discriminator
        for _, rawDiscriminator in ipairs(group.discriminators) do
            fingerprint[#fingerprint + 1] = rawDiscriminator
        end
    end
    return {commands = commands, fingerprint = table.concat(fingerprint, "\30")}
end

local function discardUpdate(state, update, reason)
    local callback = rawget(state.runtime, "onDiscardedUpdate")
    local root = plain(update) and token(
        rawget(update, "rootVehicleId"), state.deps.constants.LIMITS.idBytes)
        or nil
    local sequence = plain(update) and integer(
        rawget(update, "serverSequence"), 1,
        state.deps.constants.LIMITS.maxIdentifier) or nil
    if type(callback) ~= "function" or root == nil or sequence == nil then
        return true
    end
    local called, accepted, callbackReason = pcall(
        callback, root, sequence, reason)
    if not called or accepted == nil then
        diagnose(state, type(callbackReason) == "string" and callbackReason
            or "discardedObserverFailed", "fact", {
                rootVehicleId = root, serverSequence = sequence
            })
        return nil
    end
    return true
end

local function sequenceDisposition(state, root, sequence, fingerprint)
    local previous = state.roots[root]
    if previous ~= nil then
        if sequence < previous.sequence then
            return nil, "staleSequence"
        elseif sequence == previous.sequence then
            if fingerprint == previous.fingerprint then
                return "duplicate"
            end
            return nil, "sequenceCollision"
        end
    elseif state.rootCount >= MAX_ROOTS then
        return nil, "rootStateLimit"
    end
    return "new"
end

local function publishSequence(state, root, sequence, fingerprint)
    if state.roots[root] == nil then
        state.rootCount = state.rootCount + 1
    end
    state.roots[root] = {sequence = sequence, fingerprint = fingerprint}
end

local function handle(object, dt)
    local state = active
    if state == nil or state.disabled or not state.roleSupported then
        return nil, "inactive"
    end
    local ok, authoritative = pcall(state.runtime.isAuthoritative, object)
    if not ok then
        contractFailure(state, "authorityPortFailed", {})
        return nil, "authorityPortFailed"
    end
    if authoritative ~= true then
        return nil, "notAuthoritative"
    end
    local collected, update, collectReason, extra = pcall(
        state.runtime.getCompleteUpdate, object, dt
    )
    if not collected or extra ~= nil then
        contractFailure(state, "collectorContractViolation", {})
        return nil, "collectorContractViolation"
    end
    if update == nil then
        return rejection(state, type(collectReason) == "string"
            and collectReason or "updateUnavailable", {})
    end
    local prepared, reason, contractError = prepare(
        update, state.deps, state.parcelFallbackEnabled
    )
    if prepared == nil then
        local rootVehicleId = plain(update)
            and rawget(update, "rootVehicleId") or nil
        if contractError then
            contractFailure(state, reason, {rootVehicleId = rootVehicleId})
        else
            rejection(state, reason, {rootVehicleId = rootVehicleId})
        end
        discardUpdate(state, update, reason)
        return nil, reason
    end
    if #prepared.commands == 0 and prepared.factOnly == nil then
        discardUpdate(state, update, "noPositiveRows")
        return {accepted = false, records = 0, reason = "noPositiveRows"}
    end
    local first = prepared.factOnly or prepared.commands[1]
    local disposition, sequenceReason = sequenceDisposition(
        state, first.rootVehicleId, first.serverSequence, prepared.fingerprint
    )
    if disposition == nil then
        discardUpdate(state, update, sequenceReason)
        return rejection(state, sequenceReason, {
            rootVehicleId = first.rootVehicleId,
            serverSequence = first.serverSequence
        })
    elseif disposition == "duplicate" then
        discardUpdate(state, update, "duplicateUpdate")
        return {accepted = false, records = 0, reason = "duplicateUpdate"}
    end

    if prepared.factOnly ~= nil then
        local accept = rawget(state.runtime, "acceptFactOnly")
        if type(accept) ~= "function" then
            discardUpdate(state, update, "factOnlyRuntimeUnavailable")
            return rejection(state, "factOnlyRuntimeUnavailable", {
                rootVehicleId = first.rootVehicleId,
                serverSequence = first.serverSequence
            })
        end
        local called, result, acceptReason, acceptExtra = pcall(accept, first)
        local contractRejected = not called or acceptExtra ~= nil
            or (result ~= nil and (not plain(result)
                or not plain(rawget(result, "record"))))
            or (result == nil and type(acceptReason) ~= "string")
        if contractRejected then
            local code = not called and "coordinatorCallFailed"
                or (type(acceptReason) == "string" and acceptReason
                    or "coordinatorRejected")
            contractFailure(state, code, {
                rootVehicleId = first.rootVehicleId,
                serverSequence = first.serverSequence
            })
            discardUpdate(state, update, code)
            return nil, code
        elseif result == nil then
            rejection(state, acceptReason, {
                rootVehicleId = first.rootVehicleId,
                serverSequence = first.serverSequence
            })
            discardUpdate(state, update, acceptReason)
            return nil, acceptReason
        end
        publishSequence(state, first.rootVehicleId, first.serverSequence,
            prepared.fingerprint)
        state.consecutiveErrors = 0
        local acceptedUpdate = {
            accepted = true, activeMs = first.activeMs, factOnly = true,
            implementIds = first.implementIds, missionTime = first.missionTime,
            operatorId = first.operatorId, operatorKind = first.operatorKind,
            operatorQuality = first.operatorQuality, operations = {}, records = 1,
            rootVehicleId = first.rootVehicleId,
            serverSequence = first.serverSequence, results = {result}
        }
        local observer = rawget(state.runtime, "onAcceptedFactOnly")
        if type(observer) == "function" then
            local observed, observerResult, observerReason = pcall(
                observer, acceptedUpdate)
            if not observed or observerResult == nil then
                diagnose(state, type(observerReason) == "string"
                    and observerReason or "acceptedFactOnlyObserverFailed",
                    "fact", {
                        rootVehicleId = first.rootVehicleId,
                        serverSequence = first.serverSequence
                    })
            end
        end
        return acceptedUpdate
    end

    local results = {}
    for index, command in ipairs(prepared.commands) do
        local called, result, acceptReason, acceptExtra = pcall(
            state.runtime.acceptWork, command
        )
        local contractRejected = not called or acceptExtra ~= nil
            or (result ~= nil and not plain(result))
            or (result == nil and type(acceptReason) ~= "string")
        if contractRejected then
            local code = not called and "coordinatorCallFailed"
                or (type(acceptReason) == "string" and acceptReason
                    or "coordinatorRejected")
            contractFailure(state, code, {
                rootVehicleId = command.rootVehicleId,
                serverSequence = command.serverSequence,
                dispatched = index - 1
            })
            local close = rawget(state.runtime, "closeRoot")
            if type(close) == "function" then
                pcall(close, command.rootVehicleId, "adapterRejected", command.missionTime)
            end
            discardUpdate(state, update, code)
            return nil, code
        elseif result == nil then
            rejection(state, acceptReason, {
                rootVehicleId = command.rootVehicleId,
                serverSequence = command.serverSequence,
                dispatched = index - 1
            })
            local close = rawget(state.runtime, "closeRoot")
            if type(close) == "function" then
                pcall(close, command.rootVehicleId, "adapterRejected",
                    command.missionTime)
            end
            discardUpdate(state, update, acceptReason)
            return nil, acceptReason
        end
        results[index] = result
    end
    publishSequence(
        state, first.rootVehicleId, first.serverSequence, prepared.fingerprint
    )
    state.consecutiveErrors = 0
    local acceptedUpdate = {
        accepted = true,
        activeMs = first.activeMs,
        implementIds = first.implementIds,
        missionTime = first.missionTime,
        operatorId = first.operatorId,
        operatorKind = first.operatorKind,
        operatorQuality = first.operatorQuality,
        operations = {},
        records = #results,
        rootVehicleId = first.rootVehicleId,
        serverSequence = first.serverSequence
    }
    for index, command in ipairs(prepared.commands) do
        acceptedUpdate.operations[index] = {
            observationDiscriminator = command.observationDiscriminator,
            operationType = command.operationType,
            recordId = results[index].record.id
        }
    end
    -- Runtime observers need the authoritative cycle/session attribution when
    -- binding buffered AI-job time and cash settlements.
    acceptedUpdate.results = results
    local observer = rawget(state.runtime, "onAcceptedUpdate")
    if type(observer) == "function" then
        local observed, observerResult, observerReason = pcall(
            observer, acceptedUpdate)
        if not observed or observerResult == nil then
            diagnose(state, type(observerReason) == "string"
                and observerReason or "acceptedObserverFailed", "fact", {
                rootVehicleId = first.rootVehicleId,
                serverSequence = first.serverSequence
            })
        end
    end
    return acceptedUpdate
end

function WorkAreaAdapter.install(runtime, ...)
    if select("#", ...) ~= 0 then
        return nil, "unexpectedArgument"
    end
    if active ~= nil then
        if rawequal(active.runtime, runtime) then
            return true, false
        end
        return nil, "runtimeAlreadyInstalled"
    end
    if not plain(runtime)
        or type(rawget(runtime, "isSinglePlayer")) ~= "function"
        or type(rawget(runtime, "isAuthoritative")) ~= "function"
        or type(rawget(runtime, "getCompleteUpdate")) ~= "function"
        or type(rawget(runtime, "acceptWork")) ~= "function" then
        return nil, "invalidRuntime"
    end
    local deps, dependencyReason = dependencies()
    if deps == nil then
        return nil, dependencyReason
    end
    local ok, supported = pcall(runtime.isSinglePlayer)
    if not ok or type(supported) ~= "boolean" then
        return nil, "roleContractViolation"
    end
    local parcelFallbackEnabled = rawget(runtime, "parcelFallbackEnabled")
    if parcelFallbackEnabled ~= nil and type(parcelFallbackEnabled) ~= "boolean" then
        return nil, "invalidRuntime"
    end
    local acceptedObserver = rawget(runtime, "onAcceptedUpdate")
    if acceptedObserver ~= nil and type(acceptedObserver) ~= "function" then
        return nil, "invalidRuntime"
    end
    for _, name in ipairs({
        "acceptFactOnly", "onAcceptedFactOnly", "onDiscardedUpdate"
    }) do
        local callback = rawget(runtime, name)
        if callback ~= nil and type(callback) ~= "function" then
            return nil, "invalidRuntime"
        end
    end
    local state = {
        runtime = runtime, deps = deps, roleSupported = supported,
        parcelFallbackEnabled = parcelFallbackEnabled == true,
        disabled = false, consecutiveErrors = 0, diagnostics = {},
        omittedDiagnostics = 0, roots = {}, rootCount = 0, registration = nil
    }
    local register = rawget(runtime, "registerSealedListener")
    local unregister = rawget(runtime, "unregisterSealedListener")
    if (register == nil) ~= (unregister == nil)
        or (register ~= nil and (type(register) ~= "function"
            or type(unregister) ~= "function")) then
        return nil, "invalidRuntime"
    end
    if register ~= nil and supported then
        local registered, registration = pcall(
            register, WorkAreaAdapter.onPostUpdateTick
        )
        if not registered or registration == nil then
            return nil, "listenerRegistrationFailed"
        end
        state.registration = registration
    end
    active = state
    return true, true
end

function WorkAreaAdapter.uninstall(...)
    if select("#", ...) ~= 0 then
        return nil, "unexpectedArgument"
    end
    local state = active
    if state == nil then
        return true, false
    end
    active = nil
    if state.registration ~= nil then
        pcall(state.runtime.unregisterSealedListener, state.registration)
    end
    return true, true
end

function WorkAreaAdapter.onPostUpdateTick(object, dt, ...)
    -- This callback is registered only at the runtime's sealed post-update
    -- barrier.  The collector supplies the complete root/update row set.
    handle(object, dt)
end

-- Shared completion entry for deterministic adapter verification and the
-- supervisor-owned runtime completion barrier.
function WorkAreaAdapter.processCompleteUpdate(object, dt, ...)
    if select("#", ...) ~= 0 then
        return nil, "unexpectedArgument"
    end
    return handle(object, dt)
end

function WorkAreaAdapter.getDiagnostics(...)
    if select("#", ...) ~= 0 then
        return nil, "unexpectedArgument"
    end
    local state = active
    if state == nil then
        return {rows = {}, omittedCount = 0, disabled = false}
    end
    local rows = {}
    for index, source in ipairs(state.diagnostics) do
        local context = {}
        for key, value in pairs(source.context) do context[key] = value end
        rows[index] = {category = source.category, code = source.code, context = context}
    end
    return {rows = rows, omittedCount = state.omittedDiagnostics,
        disabled = state.disabled}
end

FieldProfitabilityLedger.Adapters.WorkAreaAdapter = WorkAreaAdapter

return WorkAreaAdapter
