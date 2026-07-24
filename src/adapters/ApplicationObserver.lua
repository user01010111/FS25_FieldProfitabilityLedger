-- Pure exact-end application observation state. Runtime class installation is
-- intentionally owned by the runtime adapter.

FieldProfitabilityLedger = FieldProfitabilityLedger or {}
FieldProfitabilityLedger.Adapters = FieldProfitabilityLedger.Adapters or {}

local ApplicationObserver = {}
ApplicationObserver.__index = ApplicationObserver

local MAX_DEPTH = 16
local MAX_DIAGNOSTICS = 64
local MAX_REASONS = 16
local MAX_TEXT_BYTES = 256
local MAX_OMITTED = 2147483647
local PRIVATE = setmetatable({}, {__mode = "k"})

local FAMILIES = {
    sowing = true,
    spraying = true
}

local LIFECYCLES = {
    save = true,
    reset = true,
    delete = true,
    detach = true,
    unload = true
}

local REASONS = {
    fingerprintUnavailable = true,
    fingerprintMismatch = true,
    priorClassWrapper = true,
    laterClassReplacement = true,
    typeShapeMismatch = true,
    typeChainBypass = true,
    typeChainMultiple = true,
    scopeOverflow = true,
    sameConsumerRecursion = true,
    overlappingSource = true,
    unwindMismatch = true,
    authorityMismatch = true,
    selectedSourceMissing = true,
    sourceMismatch = true,
    sourceTokenMismatch = true,
    unitMismatch = true,
    fillTypeMismatch = true,
    farmMismatch = true,
    directionMismatch = true,
    toolTypeMismatch = true,
    callMissing = true,
    callMultiple = true,
    returnCardinality = true,
    appliedPositive = true,
    appliedNonFinite = true,
    appliedOutOfBounds = true,
    fillError = true,
    endError = true,
    lifecycleAbort = true,
    observerFailure = true,
    transactionUnavailable = true,
    zeroAreaUnattributable = true,
    unsupportedSemantic = true
}

local function finite(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function boundedInteger(value, minimum, maximum)
    return finite(value)
        and value == math.floor(value)
        and value >= minimum
        and value <= maximum
end

local function scalarIdentity(value)
    local kind = type(value)
    if kind == "string" or kind == "boolean" then
        return true
    end
    return kind == "number" and finite(value)
end

local function text(value, maximumBytes)
    return type(value) == "string"
        and #value > 0
        and #value <= maximumBytes
        and value:find("[%z\1-\31\127]") == nil
end

local function plainTable(value)
    return type(value) == "table" and getmetatable(value) == nil
end

local function copyReasons(value, maximum, maximumBytes)
    if value == nil then
        return {}
    end
    if not plainTable(value) then
        return nil
    end
    local result = {}
    local seen = {}
    local count = 0
    for key, reason in next, value do
        count = count + 1
        if not boundedInteger(key, 1, maximum)
            or not text(reason, maximumBytes) then
            return nil
        end
        result[key] = reason
        seen[key] = true
    end
    if count > maximum then
        return nil
    end
    for index = 1, count do
        if not seen[index] then
            return nil
        end
    end
    return result
end

local function validatePolicy(policy)
    if not plainTable(policy) then
        return nil, "invalidPolicy"
    end
    local maxDepth = rawget(policy, "maxDepth")
    local maxAppliedLitres = rawget(policy, "maxAppliedLitres")
    local diagnosticCapacity = rawget(policy, "diagnosticCapacity")
    local maxReasons = rawget(policy, "maxReasons")
    local maxTextBytes = rawget(policy, "maxTextBytes")

    if not boundedInteger(maxDepth, 1, MAX_DEPTH) then
        return nil, "invalidMaxDepth"
    end
    if not finite(maxAppliedLitres) or maxAppliedLitres <= 0 then
        return nil, "invalidAppliedBound"
    end
    if not boundedInteger(diagnosticCapacity, 1, MAX_DIAGNOSTICS) then
        return nil, "invalidDiagnosticCapacity"
    end
    if not boundedInteger(maxReasons, 0, MAX_REASONS) then
        return nil, "invalidReasonCapacity"
    end
    if not boundedInteger(maxTextBytes, 1, MAX_TEXT_BYTES) then
        return nil, "invalidTextBound"
    end

    return {
        maxDepth = maxDepth,
        maxAppliedLitres = maxAppliedLitres,
        diagnosticCapacity = diagnosticCapacity,
        maxReasons = maxReasons,
        maxTextBytes = maxTextBytes
    }
end

local function validatePorts(ports)
    if not plainTable(ports)
        or type(rawget(ports, "copyToken")) ~= "function"
        or type(rawget(ports, "equalToken")) ~= "function"
        or type(rawget(ports, "resolveSourceToken")) ~= "function" then
        return nil, "invalidTokenPorts"
    end
    return {
        copyToken = rawget(ports, "copyToken"),
        equalToken = rawget(ports, "equalToken"),
        resolveSourceToken = rawget(ports, "resolveSourceToken")
    }
end

local function saturatingIncrement(value)
    if value < MAX_OMITTED then
        return value + 1
    end
    return value
end

local function recordDiagnostic(state, reason, family)
    local row = {
        reason = REASONS[reason] and reason or "observerFailure",
        family = FAMILIES[family] and family or nil
    }
    local capacity = state.policy.diagnosticCapacity
    if state.diagnosticCount < capacity then
        local index = ((state.diagnosticStart + state.diagnosticCount - 1)
            % capacity) + 1
        state.diagnostics[index] = row
        state.diagnosticCount = state.diagnosticCount + 1
    else
        state.diagnostics[state.diagnosticStart] = row
        state.diagnosticStart = (state.diagnosticStart % capacity) + 1
        state.omittedCount = saturatingIncrement(state.omittedCount)
    end
end

local function rejectScope(state, scope, reason)
    if scope ~= nil and scope.active and scope.rejection == nil then
        scope.rejection = REASONS[reason] and reason or "observerFailure"
        recordDiagnostic(state, scope.rejection, scope.family)
    end
end

local function rejectAll(state, reason)
    for index = 1, state.depth do
        rejectScope(state, state.stack[index], reason)
    end
end

local function tokenCopy(state, kind, token)
    local ok, copied = pcall(state.ports.copyToken, kind, token)
    if not ok or copied == nil then
        return nil
    end
    return copied
end

local function tokenEqual(state, kind, left, right)
    local ok, equal = pcall(state.ports.equalToken, kind, left, right)
    if not ok or type(equal) ~= "boolean" then
        return nil
    end
    return equal
end

local function resolveSourceToken(state, sourceObject)
    local ok, token = pcall(state.ports.resolveSourceToken, sourceObject)
    if not ok or token == nil then
        return nil
    end
    return token
end

local function clearScope(scope)
    scope.active = false
    scope.consumerClass = nil
    scope.consumerObject = nil
    scope.consumerToken = nil
    scope.sourceObject = nil
    scope.sourceToken = nil
    scope.unitIndex = nil
    scope.fillType = nil
    scope.fillName = nil
    scope.farmId = nil
    scope.toolType = nil
    scope.compatibilityProfile = nil
    scope.quality = nil
    scope.reasons = nil
    scope.capturedApplied = nil
    scope.captured = nil
    scope.inFlight = nil
    scope.reachCount = nil
    scope.expectedOrdinal = nil
end

local function releaseScope(state, scope)
    local handle = scope.handle
    if handle ~= nil then
        state.handles[handle] = nil
    end
    clearScope(scope)
    scope.handle = nil
end

local function abortScopes(state, reason)
    rejectAll(state, reason)
    for index = state.depth, 1, -1 do
        local scope = state.stack[index]
        state.stack[index] = nil
        releaseScope(state, scope)
    end
    state.depth = 0
end

local function scopeForHandle(state, handle)
    if type(handle) ~= "table" then
        return nil
    end
    return state.handles[handle]
end

local function openScopeImpl(state, spec)
    if not state.enabled then
        return nil, "observerDisabled"
    end
    if not plainTable(spec) then
        return nil, "invalidScope"
    end
    if state.depth >= state.policy.maxDepth then
        rejectAll(state, "scopeOverflow")
        recordDiagnostic(state, "scopeOverflow")
        return nil, "scopeOverflow"
    end

    local family = rawget(spec, "family")
    local consumerClass = rawget(spec, "consumerClass")
    local consumerObject = rawget(spec, "consumerObject")
    local sourceObject = rawget(spec, "sourceObject")
    local unitIndex = rawget(spec, "unitIndex")
    local fillType = rawget(spec, "fillType")
    local fillName = rawget(spec, "fillName")
    local farmId = rawget(spec, "farmId")
    local toolType = rawget(spec, "toolType")
    local expectedOrdinal = rawget(spec, "expectedOrdinal")
    local compatibilityProfile = rawget(spec, "compatibilityProfile")
    local quality = rawget(spec, "quality")

    if not FAMILIES[family] then
        return nil, "unsupportedSemantic"
    end
    if rawget(spec, "authority") ~= true then
        recordDiagnostic(state, "authorityMismatch", family)
        return nil, "authorityMismatch"
    end
    if consumerClass == nil or consumerObject == nil then
        return nil, "sourceMismatch"
    end
    if sourceObject == nil then
        recordDiagnostic(state, "selectedSourceMissing", family)
        return nil, "selectedSourceMissing"
    end
    if not boundedInteger(unitIndex, 1, 2147483647) then
        return nil, "unitMismatch"
    end
    if not scalarIdentity(fillType) then
        return nil, "fillTypeMismatch"
    end
    if not text(fillName, state.policy.maxTextBytes) then
        return nil, "fillTypeMismatch"
    end
    if not scalarIdentity(farmId) then
        return nil, "farmMismatch"
    end
    if not scalarIdentity(toolType) then
        return nil, "toolTypeMismatch"
    end
    -- The accepted base consumer contract has one selected FillUnit reach.
    -- Retaining the explicit ordinal makes the future wrapper expectation
    -- auditable without permitting a second matching reach to look valid.
    if expectedOrdinal ~= 1 then
        return nil, "callMissing"
    end
    if not text(compatibilityProfile, state.policy.maxTextBytes) then
        return nil, "typeShapeMismatch"
    end
    if quality ~= "Observed" then
        return nil, "unsupportedSemantic"
    end

    local reasons = copyReasons(
        rawget(spec, "reasons"),
        state.policy.maxReasons,
        state.policy.maxTextBytes
    )
    if reasons == nil then
        return nil, "unsupportedSemantic"
    end

    local consumerToken = tokenCopy(
        state,
        "consumer",
        rawget(spec, "consumerToken")
    )
    local sourceToken = tokenCopy(
        state,
        "source",
        rawget(spec, "sourceToken")
    )
    if consumerToken == nil or sourceToken == nil then
        recordDiagnostic(state, "observerFailure", family)
        return nil, "observerFailure"
    end

    local handle = {}
    local scope = {
        handle = handle,
        owner = state.owner,
        active = true,
        family = family,
        consumerClass = consumerClass,
        consumerObject = consumerObject,
        consumerToken = consumerToken,
        sourceObject = sourceObject,
        sourceToken = sourceToken,
        unitIndex = unitIndex,
        fillType = fillType,
        fillName = fillName,
        farmId = farmId,
        toolType = toolType,
        expectedOrdinal = expectedOrdinal,
        compatibilityProfile = compatibilityProfile,
        quality = quality,
        reasons = reasons,
        reachCount = 0,
        inFlight = 0,
        captured = false,
        emitted = false
    }

    for index = 1, state.depth do
        local outer = state.stack[index]
        if outer.active
            and outer.family == family
            and rawequal(outer.consumerObject, consumerObject) then
            rejectScope(state, outer, "sameConsumerRecursion")
            rejectScope(state, scope, "sameConsumerRecursion")
        end
        if outer.active
            and rawequal(outer.sourceObject, sourceObject)
            and outer.unitIndex == unitIndex
            and outer.fillType == fillType then
            rejectScope(state, outer, "overlappingSource")
            rejectScope(state, scope, "overlappingSource")
        end
    end

    state.depth = state.depth + 1
    state.stack[state.depth] = scope
    state.handles[handle] = scope
    return handle
end

local function addTicketScope(ticket, scope)
    ticket.count = ticket.count + 1
    ticket.scopes[ticket.count] = scope
    scope.inFlight = scope.inFlight + 1
end

local function beginFillImpl(state, call)
    if state.depth == 0 then
        return nil
    end
    if not plainTable(call) then
        rejectAll(state, "observerFailure")
        return nil, "observerFailure"
    end

    local sourceObject = rawget(call, "sourceObject")
    local unitIndex = rawget(call, "unitIndex")
    local fillType = rawget(call, "fillType")
    local farmId = rawget(call, "farmId")
    local delta = rawget(call, "delta")
    local toolType = rawget(call, "toolType")
    local resolvedToken = nil
    local tokenResolved = false
    local ticket = nil

    for index = 1, state.depth do
        local scope = state.stack[index]
        if scope.active
            and rawequal(scope.sourceObject, sourceObject)
            and scope.unitIndex == unitIndex
            and scope.fillType == fillType then
            if not tokenResolved then
                resolvedToken = resolveSourceToken(state, sourceObject)
                tokenResolved = true
            end
            local sameToken = resolvedToken ~= nil
                and tokenEqual(state, "source", scope.sourceToken, resolvedToken)
            if sameToken == nil then
                rejectScope(state, scope, "observerFailure")
            elseif not sameToken then
                rejectScope(state, scope, "sourceTokenMismatch")
            elseif farmId ~= scope.farmId then
                rejectScope(state, scope, "farmMismatch")
            elseif not finite(delta) or delta >= 0 then
                rejectScope(state, scope, "directionMismatch")
            elseif toolType ~= scope.toolType then
                rejectScope(state, scope, "toolTypeMismatch")
            else
                scope.reachCount = scope.reachCount + 1
                if scope.inFlight > 0 then
                    rejectScope(state, scope, "sameConsumerRecursion")
                end
                if scope.reachCount == scope.expectedOrdinal then
                    if ticket == nil then
                        ticket = {
                            owner = state.owner,
                            active = true,
                            scopes = {},
                            count = 0
                        }
                    end
                    addTicketScope(ticket, scope)
                elseif scope.reachCount > scope.expectedOrdinal then
                    rejectScope(state, scope, "callMultiple")
                end
            end
        end
    end

    return ticket
end

local function validTicket(state, ticket)
    return type(ticket) == "table"
        and rawequal(ticket.owner, state.owner)
        and ticket.active == true
        and plainTable(ticket.scopes)
        and boundedInteger(ticket.count, 1, state.policy.maxDepth)
end

local function finishTicket(state, ticket, packed, failure)
    if not validTicket(state, ticket) then
        return nil, "invalidTicket"
    end
    ticket.active = false

    local cardinality = nil
    local applied = nil
    if failure == nil then
        if not plainTable(packed)
            or rawget(packed, "n") ~= 1 then
            cardinality = "returnCardinality"
        else
            applied = rawget(packed, 1)
            if not finite(applied) then
                cardinality = "appliedNonFinite"
            elseif applied > 0 then
                cardinality = "appliedPositive"
            elseif -applied > state.policy.maxAppliedLitres then
                cardinality = "appliedOutOfBounds"
            end
        end
    end

    for index = 1, ticket.count do
        local scope = ticket.scopes[index]
        ticket.scopes[index] = nil
        if scope.active then
            scope.inFlight = math.max(0, scope.inFlight - 1)
            if failure ~= nil then
                rejectScope(state, scope, failure)
            elseif cardinality ~= nil then
                rejectScope(state, scope, cardinality)
            elseif scope.captured then
                rejectScope(state, scope, "callMultiple")
            else
                scope.capturedApplied = applied
                scope.captured = true
            end
        end
    end
    ticket.owner = nil
    ticket.scopes = nil
    ticket.count = nil
    return cardinality == nil and failure == nil,
        cardinality or failure
end

local function closeScopeImpl(state, handle, reason)
    local scope = scopeForHandle(state, handle)
    if scope == nil then
        return nil, "invalidScope"
    end
    if not scope.active then
        return nil, scope.rejection or "lifecycleAbort"
    end
    if state.depth == 0 or not rawequal(state.stack[state.depth], scope) then
        abortScopes(state, "unwindMismatch")
        state.enabled = false
        return nil, "unwindMismatch"
    end

    state.stack[state.depth] = nil
    state.depth = state.depth - 1
    if reason ~= nil then
        rejectScope(state, scope, REASONS[reason] and reason or "observerFailure")
    end
    if scope.inFlight > 0 then
        rejectScope(state, scope, "callMissing")
    end
    if scope.reachCount < scope.expectedOrdinal then
        rejectScope(state, scope, "callMissing")
    elseif scope.reachCount > scope.expectedOrdinal then
        rejectScope(state, scope, "callMultiple")
    end
    if not scope.captured and scope.rejection == nil then
        rejectScope(state, scope, "callMissing")
    end

    local rejection = scope.rejection
    local applied = scope.capturedApplied
    local family = scope.family
    local consumerToken = scope.consumerToken
    local sourceToken = scope.sourceToken
    local farmId = scope.farmId
    local fillName = scope.fillName
    local toolType = scope.toolType
    local compatibilityProfile = scope.compatibilityProfile
    local quality = scope.quality
    local reasons = scope.reasons

    -- Engine objects and the unit/type indices are erased before any detached
    -- copy is attempted or returned to downstream code.
    scope.consumerClass = nil
    scope.consumerObject = nil
    scope.sourceObject = nil
    scope.unitIndex = nil
    scope.fillType = nil

    if rejection ~= nil or applied == nil or applied == 0 or scope.emitted then
        releaseScope(state, scope)
        return nil, rejection
    end

    local detachedConsumer = tokenCopy(state, "consumer", consumerToken)
    local detachedSource = tokenCopy(state, "source", sourceToken)
    local detachedReasons = copyReasons(
        reasons,
        state.policy.maxReasons,
        state.policy.maxTextBytes
    )
    if detachedConsumer == nil or detachedSource == nil
        or detachedReasons == nil then
        recordDiagnostic(state, "observerFailure", family)
        releaseScope(state, scope)
        return nil, "observerFailure"
    end

    local fact = {
        family = family,
        consumerToken = detachedConsumer,
        sourceToken = detachedSource,
        farmId = farmId,
        fillName = fillName,
        toolType = toolType,
        compatibilityProfile = compatibilityProfile,
        appliedLitres = -applied,
        quality = quality,
        reasons = detachedReasons
    }
    scope.emitted = true
    releaseScope(state, scope)
    return fact
end

local function guarded(state, implementation, ...)
    local ok, first, second = pcall(implementation, state, ...)
    if ok then
        return first, second
    end
    rejectAll(state, "observerFailure")
    recordDiagnostic(state, "observerFailure")
    return nil, "observerFailure"
end

function ApplicationObserver.new(policy, ports, ...)
    if select("#", ...) ~= 0 then
        return nil, "unexpectedArgument"
    end
    local normalizedPolicy, policyError = validatePolicy(policy)
    if normalizedPolicy == nil then
        return nil, policyError
    end
    local normalizedPorts, portsError = validatePorts(ports)
    if normalizedPorts == nil then
        return nil, portsError
    end

    local self = setmetatable({}, ApplicationObserver)
    local state = {
        owner = {},
        enabled = true,
        policy = normalizedPolicy,
        ports = normalizedPorts,
        stack = {},
        handles = setmetatable({}, {__mode = "k"}),
        depth = 0,
        diagnostics = {},
        diagnosticStart = 1,
        diagnosticCount = 0,
        omittedCount = 0
    }
    PRIVATE[self] = state
    return self
end

local function getState(self)
    local state = PRIVATE[self]
    if state == nil then
        return nil, "invalidObserver"
    end
    return state
end

function ApplicationObserver.hasOpenScopes(self, ...)
    if select("#", ...) ~= 0 then
        return false
    end
    local state = PRIVATE[self]
    return state ~= nil and state.depth ~= 0
end

function ApplicationObserver.getDepth(self, ...)
    if select("#", ...) ~= 0 then
        return nil, "unexpectedArgument"
    end
    local state, reason = getState(self)
    if state == nil then
        return nil, reason
    end
    return state.depth
end

function ApplicationObserver.openScope(self, spec, ...)
    if select("#", ...) ~= 0 then
        return nil, "unexpectedArgument"
    end
    local state, reason = getState(self)
    if state == nil then
        return nil, reason
    end
    return guarded(state, openScopeImpl, spec)
end

function ApplicationObserver.beginFillCall(self, call, ...)
    if select("#", ...) ~= 0 then
        return nil, "unexpectedArgument"
    end
    local state, reason = getState(self)
    if state == nil then
        return nil, reason
    end
    -- The depth-zero branch returns before inspecting the call table, invoking
    -- a token port, scanning a scope, or allocating a match ticket.
    if state.depth == 0 then
        return nil
    end
    return guarded(state, beginFillImpl, call)
end

function ApplicationObserver.completeFillCall(self, ticket, packed, ...)
    if select("#", ...) ~= 0 then
        return nil, "unexpectedArgument"
    end
    local state, reason = getState(self)
    if state == nil then
        return nil, reason
    end
    return guarded(state, finishTicket, ticket, packed, nil)
end

function ApplicationObserver.failFillCall(self, ticket, ...)
    if select("#", ...) ~= 0 then
        return nil, "unexpectedArgument"
    end
    local state, reason = getState(self)
    if state == nil then
        return nil, reason
    end
    return guarded(state, finishTicket, ticket, nil, "fillError")
end

function ApplicationObserver.rejectScope(self, scope, reason, ...)
    if select("#", ...) ~= 0 then
        return nil, "unexpectedArgument"
    end
    local state, stateError = getState(self)
    if state == nil then
        return nil, stateError
    end
    local internalScope = scopeForHandle(state, scope)
    if internalScope == nil or not REASONS[reason] then
        return nil, "invalidRejection"
    end
    rejectScope(state, internalScope, reason)
    return true
end

function ApplicationObserver.closeScope(self, scope, reason, ...)
    if select("#", ...) ~= 0 then
        return nil, "unexpectedArgument"
    end
    local state, stateError = getState(self)
    if state == nil then
        return nil, stateError
    end
    if reason ~= nil and not REASONS[reason] then
        reason = "observerFailure"
    end
    return guarded(state, closeScopeImpl, scope, reason)
end

function ApplicationObserver.abortLifecycle(self, lifecycle, ...)
    if select("#", ...) ~= 0 then
        return nil, "unexpectedArgument"
    end
    local state, reason = getState(self)
    if state == nil then
        return nil, reason
    end
    if not LIFECYCLES[lifecycle] then
        return nil, "invalidLifecycle"
    end
    abortScopes(state, "lifecycleAbort")
    if lifecycle == "unload" then
        state.enabled = false
        state.diagnostics = {}
        state.diagnosticStart = 1
        state.diagnosticCount = 0
        state.omittedCount = 0
    end
    return true
end

function ApplicationObserver.getDiagnostics(self, ...)
    if select("#", ...) ~= 0 then
        return nil, "unexpectedArgument"
    end
    local state, reason = getState(self)
    if state == nil then
        return nil, reason
    end
    local rows = {}
    local capacity = state.policy.diagnosticCapacity
    for offset = 0, state.diagnosticCount - 1 do
        local index = ((state.diagnosticStart + offset - 1) % capacity) + 1
        local row = state.diagnostics[index]
        rows[#rows + 1] = {
            reason = row.reason,
            family = row.family
        }
    end
    return {
        rows = rows,
        omittedCount = state.omittedCount
    }
end

FieldProfitabilityLedger.Adapters.ApplicationObserver = ApplicationObserver

return ApplicationObserver
