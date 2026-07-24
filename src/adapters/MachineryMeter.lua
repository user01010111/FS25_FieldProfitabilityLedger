-- Engine-neutral per-root/update machinery sampler. Real FS25 listener and
-- Motorized wrapper installation are owned by the runtime adapter.

FieldProfitabilityLedger = FieldProfitabilityLedger or {}
FieldProfitabilityLedger.Adapters = FieldProfitabilityLedger.Adapters or {}

local MachineryMeter = {}
MachineryMeter.__index = MachineryMeter

local PRIVATE = setmetatable({}, {__mode = "k"})
local MAX_DIAGNOSTICS = 64
local MAX_PENDING = 256
local MAX_OBJECTS = 128
local MAX_REASONS = 16
local MAX_TEXT_BYTES = 256
local MAX_IDENTIFIER = 9007199254740991

local CONSUMER_CATEGORIES = {fuel = true, def = true}
local ROLES = {root = true, implement = true}
local OPERATORS = {player = true, ai = true, unknown = true}
local LIFECYCLES = {
    delete = true, detach = true, load = true, reset = true,
    save = true, unload = true
}

local CONSUMER_SAMPLE_KEYS = {
    authority = true, complete = true, rootVehicleId = true,
    rows = true, serverSequence = true
}
local CONSUMER_ROW_KEYS = {
    afterEffective = true, beforeEffective = true, category = true,
    consumerId = true, fillName = true
}
local OBJECT_KEYS = {
    authority = true, damageAfter = true, damageBefore = true,
    objectId = true, operatingAfter = true, operatingBefore = true,
    repairValueAfter = true, repairValueBefore = true, role = true,
    rootVehicleId = true, serverSequence = true, wearAfter = true,
    wearBefore = true
}
local EVIDENCE_KEYS = {
    activeMs = true, complete = true, implementIds = true,
    landUpdateToken = true, operatorId = true, operatorKind = true,
    quality = true, reasons = true, rootVehicleId = true,
    serverSequence = true
}

local function finite(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function integer(value, minimum, maximum)
    return finite(value) and value == math.floor(value)
        and value >= minimum and value <= maximum
end

local function plain(value)
    return type(value) == "table" and getmetatable(value) == nil
end

local function text(value, maximum)
    return type(value) == "string" and #value > 0 and #value <= maximum
        and value:find("[%z\1-\31\127]") == nil
end

local function closed(value, allowed, maximum)
    if not plain(value) then return false end
    local count = 0
    for key in next, value do
        count = count + 1
        if count > maximum or type(key) ~= "string" or allowed[key] ~= true then
            return false
        end
    end
    return true
end

local function dense(value, maximum)
    if not plain(value) then return nil end
    local count = 0
    for key in next, value do
        if not integer(key, 1, maximum) then return nil end
        count = count + 1
    end
    if count > maximum then return nil end
    for index = 1, count do
        if rawget(value, index) == nil then return nil end
    end
    return count
end

local function copyReasons(value, policy)
    if value == nil then return {} end
    local count = dense(value, policy.maxReasons)
    if count == nil then return nil end
    local result = {}
    for index = 1, count do
        local reason = rawget(value, index)
        if not text(reason, policy.maxTextBytes) then return nil end
        result[index] = reason
    end
    return result
end

local function copyIds(value, policy)
    local count = dense(value, policy.maxObjects)
    if count == nil then return nil end
    local result, seen = {}, {}
    for index = 1, count do
        local id = rawget(value, index)
        if not text(id, policy.maxTextBytes) or seen[id] then return nil end
        seen[id] = true
        result[index] = id
    end
    table.sort(result)
    return result
end

local function validatePolicy(policy)
    if not plain(policy) then return nil, "invalidPolicy" end
    local result = {
        maxPhysical = rawget(policy, "maxPhysical"),
        maxDurationMs = rawget(policy, "maxDurationMs"),
        maxMoney = rawget(policy, "maxMoney"),
        maxRatio = rawget(policy, "maxRatio"),
        diagnosticCapacity = rawget(policy, "diagnosticCapacity"),
        maxPending = rawget(policy, "maxPending"),
        maxObjects = rawget(policy, "maxObjects"),
        maxReasons = rawget(policy, "maxReasons"),
        maxTextBytes = rawget(policy, "maxTextBytes")
    }
    if not finite(result.maxPhysical) or result.maxPhysical <= 0 then
        return nil, "invalidPhysicalBound"
    end
    if not finite(result.maxDurationMs) or result.maxDurationMs <= 0 then
        return nil, "invalidDurationBound"
    end
    if not finite(result.maxMoney) or result.maxMoney <= 0 then
        return nil, "invalidMoneyBound"
    end
    if not finite(result.maxRatio) or result.maxRatio <= 0
        or result.maxRatio > 1 then
        return nil, "invalidRatioBound"
    end
    if not integer(result.diagnosticCapacity, 1, MAX_DIAGNOSTICS)
        or not integer(result.maxPending, 1, MAX_PENDING)
        or not integer(result.maxObjects, 1, MAX_OBJECTS)
        or not integer(result.maxReasons, 0, MAX_REASONS)
        or not integer(result.maxTextBytes, 1, MAX_TEXT_BYTES) then
        return nil, "invalidCapacity"
    end
    return result
end

local function sequenceKey(rootVehicleId, serverSequence)
    return #rootVehicleId .. ":" .. rootVehicleId .. ":"
        .. string.format("%.17g", serverSequence)
end

local function diagnostic(state, reason, rootVehicleId, serverSequence)
    local row = {
        reason = reason, rootVehicleId = rootVehicleId,
        serverSequence = serverSequence
    }
    if #state.diagnostics < state.policy.diagnosticCapacity then
        state.diagnostics[#state.diagnostics + 1] = row
    else
        table.remove(state.diagnostics, 1)
        state.diagnostics[#state.diagnostics + 1] = row
        state.omitted = math.min(2147483647, state.omitted + 1)
    end
end

local function validateIdentity(state, value)
    if not closed(value, {
        authority = true, rootVehicleId = true, serverSequence = true
    }, 3) then
        return nil, "invalidIdentity"
    end
    if rawget(value, "authority") ~= true
        or not text(rawget(value, "rootVehicleId"), state.policy.maxTextBytes)
        or not integer(rawget(value, "serverSequence"), 0, MAX_IDENTIFIER) then
        return nil, "invalidIdentity"
    end
    return rawget(value, "rootVehicleId"), rawget(value, "serverSequence")
end

local function getEntry(state, rootVehicleId, serverSequence, create)
    local key = sequenceKey(rootVehicleId, serverSequence)
    if state.finalized[key] then return nil, "sequenceFinalized" end
    local entry = state.pending[key]
    if entry == nil and create then
        if state.pendingCount >= state.policy.maxPending then
            return nil, "pendingCapacity"
        end
        entry = {
            rootVehicleId = rootVehicleId,
            serverSequence = serverSequence,
            consumers = nil,
            objects = {}, objectCount = 0,
            evidence = nil
        }
        state.pending[key] = entry
        state.pendingCount = state.pendingCount + 1
    end
    return entry, key
end

local function validateConsumerRows(state, rows)
    local count = dense(rows, state.policy.maxObjects)
    if count == nil then return nil, "invalidConsumerRows" end
    local result, seen = {}, {}
    for index = 1, count do
        local row = rawget(rows, index)
        if not closed(row, CONSUMER_ROW_KEYS, 5) then
            return nil, "invalidConsumerRow"
        end
        local category = rawget(row, "category")
        local consumerId = rawget(row, "consumerId")
        local fillName = rawget(row, "fillName")
        local before = rawget(row, "beforeEffective")
        local after = rawget(row, "afterEffective")
        if not CONSUMER_CATEGORIES[category]
            or not text(consumerId, state.policy.maxTextBytes)
            or not text(fillName, state.policy.maxTextBytes)
            or not finite(before) or not finite(after)
            or before < 0 or after < 0
            or before > state.policy.maxPhysical
            or after > state.policy.maxPhysical then
            return nil, "invalidConsumerRow"
        end
        local identity = category .. "\31" .. consumerId
        if seen[identity] then return nil, "duplicateConsumer" end
        seen[identity] = true
        local delta = before - after
        local status = "zero"
        if delta > state.policy.maxPhysical then
            return nil, "consumerDeltaOutOfBounds"
        elseif delta > 0 then
            status = "consumed"
        elseif delta < 0 then
            status = "rebaseline"
        end
        result[index] = {
            category = category, consumerId = consumerId,
            fillName = fillName, status = status,
            consumedLitres = status == "consumed" and delta or nil
        }
    end
    return result
end

local function stageConsumersImpl(state, sample)
    if not closed(sample, CONSUMER_SAMPLE_KEYS, 5)
        or rawget(sample, "authority") ~= true
        or rawget(sample, "complete") ~= true
        or not text(rawget(sample, "rootVehicleId"), state.policy.maxTextBytes)
        or not integer(rawget(sample, "serverSequence"), 0, MAX_IDENTIFIER) then
        return nil, "invalidConsumerSample"
    end
    local rows, reason = validateConsumerRows(state, rawget(sample, "rows"))
    if rows == nil then return nil, reason end
    local entry, keyOrReason = getEntry(state, sample.rootVehicleId,
        sample.serverSequence, true)
    if entry == nil then return nil, keyOrReason end
    if entry.consumers ~= nil then
        return nil, "consumerSampleCollision"
    end
    entry.consumers = rows
    return true
end

local function delta(before, after, maximum)
    if not finite(before) or not finite(after)
        or before < 0 or after < 0 or before > maximum or after > maximum then
        return nil, "invalidState"
    end
    local change = after - before
    if change < 0 then return nil, "rebaseline" end
    if change > maximum then return nil, "deltaOutOfBounds" end
    return change
end

local function stageObjectImpl(state, sample)
    if not closed(sample, OBJECT_KEYS, 13)
        or rawget(sample, "authority") ~= true
        or not text(rawget(sample, "rootVehicleId"), state.policy.maxTextBytes)
        or not text(rawget(sample, "objectId"), state.policy.maxTextBytes)
        or not integer(rawget(sample, "serverSequence"), 0, MAX_IDENTIFIER)
        or not ROLES[rawget(sample, "role")] then
        return nil, "invalidObjectSample"
    end
    if sample.role == "root" and sample.objectId ~= sample.rootVehicleId then
        return nil, "rootIdentityMismatch"
    end
    local operating, operatingReason = delta(sample.operatingBefore,
        sample.operatingAfter, state.policy.maxDurationMs)
    local damage, damageReason = delta(sample.damageBefore, sample.damageAfter,
        state.policy.maxRatio)
    local wear, wearReason = delta(sample.wearBefore, sample.wearAfter,
        state.policy.maxRatio)
    local repair, repairReason = delta(sample.repairValueBefore,
        sample.repairValueAfter, state.policy.maxMoney)
    if operatingReason == "invalidState" or operatingReason == "deltaOutOfBounds"
        or damageReason == "invalidState" or damageReason == "deltaOutOfBounds"
        or wearReason == "invalidState" or wearReason == "deltaOutOfBounds"
        or repairReason == "invalidState" or repairReason == "deltaOutOfBounds" then
        return nil, "invalidObjectState"
    end

    local entry, keyOrReason = getEntry(state, sample.rootVehicleId,
        sample.serverSequence, true)
    if entry == nil then return nil, keyOrReason end
    if entry.objects[sample.objectId] ~= nil then
        return nil, "objectSampleCollision"
    end
    if entry.objectCount >= state.policy.maxObjects then
        return nil, "objectCapacity"
    end
    entry.objects[sample.objectId] = {
        objectId = sample.objectId, role = sample.role,
        operatingMs = operating,
        damageDelta = damage,
        wearDelta = wear,
        repairLiability = repair,
        operatingStatus = operatingReason or "observed",
        damageStatus = damageReason or "observed",
        wearStatus = wearReason or "observed",
        repairStatus = repairReason or "observed"
    }
    entry.objectCount = entry.objectCount + 1
    return true
end

local function tagEvidenceImpl(state, evidence)
    if not closed(evidence, EVIDENCE_KEYS, 10)
        or rawget(evidence, "complete") ~= true
        or not text(rawget(evidence, "rootVehicleId"), state.policy.maxTextBytes)
        or not integer(rawget(evidence, "serverSequence"), 0, MAX_IDENTIFIER)
        or not finite(rawget(evidence, "activeMs"))
        or evidence.activeMs < 0
        or evidence.activeMs > state.policy.maxDurationMs
        or not text(rawget(evidence, "landUpdateToken"), state.policy.maxTextBytes)
        or not OPERATORS[rawget(evidence, "operatorKind")]
        or rawget(evidence, "quality") ~= "Complete" then
        return nil, "invalidEvidence"
    end
    if evidence.operatorId ~= nil
        and not text(evidence.operatorId, state.policy.maxTextBytes) then
        return nil, "invalidEvidence"
    end
    local implementIds = copyIds(evidence.implementIds, state.policy)
    local reasons = copyReasons(evidence.reasons, state.policy)
    if implementIds == nil or reasons == nil then return nil, "invalidEvidence" end
    local entry, keyOrReason = getEntry(state, evidence.rootVehicleId,
        evidence.serverSequence, true)
    if entry == nil then return nil, keyOrReason end
    if entry.evidence ~= nil then return nil, "evidenceCollision" end
    entry.evidence = {
        activeMs = evidence.activeMs,
        landUpdateToken = evidence.landUpdateToken,
        operatorKind = evidence.operatorKind,
        operatorId = evidence.operatorId,
        implementIds = implementIds,
        reasons = reasons
    }
    return true
end

local function removeEntry(state, key)
    if state.pending[key] ~= nil then
        state.pending[key] = nil
        state.pendingCount = state.pendingCount - 1
    end
end

local function markFinalized(state, key)
    state.finalized[key] = true
    state.finalizedOrder[#state.finalizedOrder + 1] = key
    while #state.finalizedOrder > state.policy.maxPending do
        local old = table.remove(state.finalizedOrder, 1)
        state.finalized[old] = nil
    end
end

local function finalizeImpl(state, identity)
    local rootVehicleId, serverSequence = validateIdentity(state, identity)
    if rootVehicleId == nil then return nil, serverSequence end
    local key = sequenceKey(rootVehicleId, serverSequence)
    if state.finalized[key] then return nil, "duplicateSequence" end
    local entry = state.pending[key]
    if entry == nil then return nil, "sequenceMissing" end
    if entry.evidence == nil then
        removeEntry(state, key)
        diagnostic(state, "noAcceptedEvidence", rootVehicleId, serverSequence)
        markFinalized(state, key)
        return nil, "noAcceptedEvidence"
    end

    local relevant = {[rootVehicleId] = true}
    for _, id in ipairs(entry.evidence.implementIds) do relevant[id] = true end
    local objects = {}
    for objectId, row in pairs(entry.objects) do
        if relevant[objectId] then
            objects[#objects + 1] = {
                objectId = row.objectId, role = row.role,
                operatingMs = row.operatingMs,
                damageDelta = row.damageDelta,
                wearDelta = row.wearDelta,
                repairLiability = row.repairLiability,
                operatingStatus = row.operatingStatus,
                damageStatus = row.damageStatus,
                wearStatus = row.wearStatus,
                repairStatus = row.repairStatus
            }
        end
    end
    table.sort(objects, function(left, right) return left.objectId < right.objectId end)

    local consumers = {}
    for _, row in ipairs(entry.consumers or {}) do
        consumers[#consumers + 1] = {
            category = row.category, consumerId = row.consumerId,
            fillName = row.fillName, status = row.status,
            consumedLitres = row.consumedLitres
        }
    end
    table.sort(consumers, function(left, right)
        if left.category ~= right.category then return left.category < right.category end
        return left.consumerId < right.consumerId
    end)

    local evidence = entry.evidence
    local fact = {
        rootVehicleId = rootVehicleId,
        serverSequence = serverSequence,
        landUpdateToken = evidence.landUpdateToken,
        activeMs = evidence.activeMs,
        workingTimeMs = evidence.activeMs,
        operatorKind = evidence.operatorKind,
        operatorId = evidence.operatorId,
        aiLabourMs = evidence.operatorKind == "ai" and evidence.activeMs or nil,
        playerLabourMs = evidence.operatorKind == "player"
            and evidence.activeMs or nil,
        consumers = consumers,
        objects = objects,
        quality = "Observed",
        reasons = copyReasons(evidence.reasons, state.policy)
    }
    removeEntry(state, key)
    markFinalized(state, key)
    return fact
end

local function discardImpl(state, identity)
    local rootVehicleId, serverSequence = validateIdentity(state, identity)
    if rootVehicleId == nil then return nil, serverSequence end
    local key = sequenceKey(rootVehicleId, serverSequence)
    if state.finalized[key] then return false end
    local existed = state.pending[key] ~= nil
    removeEntry(state, key)
    return existed
end

local function guarded(state, implementation, ...)
    local ok, first, second = pcall(implementation, state, ...)
    if ok then return first, second end
    diagnostic(state, "observerFailure")
    return nil, "observerFailure"
end

local function getState(self)
    local state = PRIVATE[self]
    if state == nil then return nil, "invalidMeter" end
    return state
end

function MachineryMeter.new(policy, ...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    local normalized, reason = validatePolicy(policy)
    if normalized == nil then return nil, reason end
    local self = setmetatable({}, MachineryMeter)
    PRIVATE[self] = {
        policy = normalized, pending = {}, pendingCount = 0,
        finalized = {}, finalizedOrder = {}, diagnostics = {}, omitted = 0
    }
    return self
end

function MachineryMeter.stageConsumers(self, sample, ...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    local state, reason = getState(self)
    if state == nil then return nil, reason end
    return guarded(state, stageConsumersImpl, sample)
end

function MachineryMeter.stageObject(self, sample, ...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    local state, reason = getState(self)
    if state == nil then return nil, reason end
    return guarded(state, stageObjectImpl, sample)
end

function MachineryMeter.tagEvidence(self, evidence, ...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    local state, reason = getState(self)
    if state == nil then return nil, reason end
    return guarded(state, tagEvidenceImpl, evidence)
end

function MachineryMeter.finalizeSequence(self, identity, ...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    local state, reason = getState(self)
    if state == nil then return nil, reason end
    return guarded(state, finalizeImpl, identity)
end

function MachineryMeter.discardSequence(self, identity, ...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    local state, reason = getState(self)
    if state == nil then return nil, reason end
    return guarded(state, discardImpl, identity)
end

function MachineryMeter.abortLifecycle(self, lifecycle, ...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    local state, reason = getState(self)
    if state == nil then return nil, reason end
    if not LIFECYCLES[lifecycle] then return nil, "invalidLifecycle" end
    state.pending = {}
    state.pendingCount = 0
    if lifecycle == "load" or lifecycle == "reset" or lifecycle == "unload" then
        state.finalized = {}
        state.finalizedOrder = {}
    end
    return true
end

function MachineryMeter.getDiagnostics(self, ...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    local state, reason = getState(self)
    if state == nil then return nil, reason end
    local rows = {}
    for index, row in ipairs(state.diagnostics) do
        rows[index] = {
            reason = row.reason, rootVehicleId = row.rootVehicleId,
            serverSequence = row.serverSequence
        }
    end
    return {rows = rows, omitted = state.omitted}
end

FieldProfitabilityLedger.Adapters.MachineryMeter = MachineryMeter
return MachineryMeter
