-- Pure matcher for one eligible Combine:addCutterArea return. Real FS25 class
-- Binding and land joining are owned by the runtime integration layer.

FieldProfitabilityLedger = FieldProfitabilityLedger or {}
FieldProfitabilityLedger.Adapters = FieldProfitabilityLedger.Adapters or {}

local HarvestObserver = {}
HarvestObserver.__index = HarvestObserver

local MAX_DEPTH = 16
local MAX_DIAGNOSTICS = 64
local MAX_REPLAY = 256
local MAX_TEXT_BYTES = 256
local MAX_REASONS = 16
local MAX_IDENTIFIER = 9007199254740991
local PRIVATE = setmetatable({}, {__mode = "k"})

local LIFECYCLES = {
    delete = true, detach = true, reset = true, save = true, unload = true
}

local TRACKED_CHAIN_FAMILIES = {
    conventionalTank = true,
    maizeHeaderTank = true,
    integratedTank = true,
    rootTank = true,
    directDischarge = true,
    cottonBuffer = true,
    vineTank = true,
    convertedOutput = true,
    topLiftingDirectDischarge = true
}

local DIRECT_CHAIN_FAMILIES = {
    directDischarge = true,
    topLiftingDirectDischarge = true
}

-- Poplar is converted to WOODCHIPS at the cutter seam. Base-game machines
-- expose that same crop contract through both a finite BioBaler buffer and an
-- infinite forage-harvester discharge, so storage shape is deliberately not
-- part of this family's eligibility identity.
local FLEXIBLE_CHAIN_FAMILIES = {convertedOutput = true}

local SPEC_KEYS = {
    authority = true, callDiscriminator = true, chainFamily = true,
    combineId = true, compatibilityProfile = true, directDischarge = true,
    eligible = true, farmId = true, finiteTank = true, headerId = true,
    inputFruitName = true, inputFruitType = true, landUpdateToken = true,
    outputFillName = true, outputFillType = true, reasons = true,
    rootVehicleId = true, serverSequence = true
}

local REACH_KEYS = {
    callDiscriminator = true, combineId = true, farmId = true,
    headerId = true, inputFruitType = true, landUpdateToken = true,
    outputFillType = true, rootVehicleId = true, serverSequence = true
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

local function closed(value, keys)
    if not plain(value) then return false end
    local count = 0
    for key in next, value do
        count = count + 1
        if count > 32 or type(key) ~= "string" or keys[key] ~= true then
            return false
        end
    end
    return true
end

local function text(value, maximum)
    return type(value) == "string" and #value > 0 and #value <= maximum
        and value:find("[%z\1-\31\127]") == nil
end

local function scalar(value, maximum)
    local kind = type(value)
    return kind == "string" and text(value, maximum)
        or kind == "number" and finite(value)
end

local function copyReasons(value, policy)
    if value == nil then return {} end
    if not plain(value) then return nil end
    local count = 0
    for key in next, value do
        if not integer(key, 1, policy.maxReasons) then return nil end
        count = count + 1
    end
    if count > policy.maxReasons then return nil end
    local result = {}
    for index = 1, count do
        local reason = rawget(value, index)
        if not text(reason, policy.maxTextBytes) then return nil end
        result[index] = reason
    end
    return result
end

local function validatePolicy(policy)
    if not plain(policy) then return nil, "invalidPolicy" end
    local result = {
        maxDepth = rawget(policy, "maxDepth"),
        maxHarvestedLitres = rawget(policy, "maxHarvestedLitres"),
        diagnosticCapacity = rawget(policy, "diagnosticCapacity"),
        replayCapacity = rawget(policy, "replayCapacity"),
        maxReasons = rawget(policy, "maxReasons"),
        maxTextBytes = rawget(policy, "maxTextBytes")
    }
    if not integer(result.maxDepth, 1, MAX_DEPTH) then
        return nil, "invalidMaxDepth"
    end
    if not finite(result.maxHarvestedLitres)
        or result.maxHarvestedLitres <= 0 then
        return nil, "invalidHarvestBound"
    end
    if not integer(result.diagnosticCapacity, 1, MAX_DIAGNOSTICS) then
        return nil, "invalidDiagnosticCapacity"
    end
    if not integer(result.replayCapacity, 1, MAX_REPLAY) then
        return nil, "invalidReplayCapacity"
    end
    if not integer(result.maxReasons, 0, MAX_REASONS) then
        return nil, "invalidReasonCapacity"
    end
    if not integer(result.maxTextBytes, 1, MAX_TEXT_BYTES) then
        return nil, "invalidTextBound"
    end
    return result
end

local function diagnostic(state, reason, rootVehicleId)
    local row = {reason = reason, rootVehicleId = rootVehicleId}
    if #state.diagnostics < state.policy.diagnosticCapacity then
        state.diagnostics[#state.diagnostics + 1] = row
    else
        table.remove(state.diagnostics, 1)
        state.diagnostics[#state.diagnostics + 1] = row
        state.omittedDiagnostics = math.min(2147483647,
            state.omittedDiagnostics + 1)
    end
end

local function reject(state, scope, reason)
    if scope ~= nil and scope.active and scope.rejection == nil then
        scope.rejection = reason
        diagnostic(state, reason, scope.rootVehicleId)
    end
end

local function clearScope(scope)
    for key in next, scope do scope[key] = nil end
end

local function abortAll(state, reason)
    for index = state.depth, 1, -1 do
        local scope = state.stack[index]
        reject(state, scope, reason)
        state.stack[index] = nil
        clearScope(scope)
    end
    state.depth = 0
end

local function same(left, right)
    return type(left) == type(right) and left == right
end

local function identityMatches(scope, reach)
    return same(scope.combineId, rawget(reach, "combineId"))
        and same(scope.headerId, rawget(reach, "headerId"))
        and same(scope.rootVehicleId, rawget(reach, "rootVehicleId"))
        and same(scope.serverSequence, rawget(reach, "serverSequence"))
        and same(scope.callDiscriminator, rawget(reach, "callDiscriminator"))
        and same(scope.farmId, rawget(reach, "farmId"))
        and same(scope.inputFruitType, rawget(reach, "inputFruitType"))
        and same(scope.outputFillType, rawget(reach, "outputFillType"))
        and same(scope.landUpdateToken, rawget(reach, "landUpdateToken"))
end

local function copySpec(state, spec)
    if not closed(spec, SPEC_KEYS) then return nil, "invalidContext" end
    if rawget(spec, "authority") ~= true then return nil, "authorityMismatch" end
    local chainFamily = rawget(spec, "chainFamily")
    local finiteTank = rawget(spec, "finiteTank")
    local directDischarge = rawget(spec, "directDischarge")
    if rawget(spec, "eligible") ~= true
        or TRACKED_CHAIN_FAMILIES[chainFamily] ~= true
        or type(rawget(spec, "finiteTank")) ~= "boolean"
        or type(rawget(spec, "directDischarge")) ~= "boolean"
        or finiteTank == directDischarge
        or (DIRECT_CHAIN_FAMILIES[chainFamily] == true
            and directDischarge ~= true)
        or (DIRECT_CHAIN_FAMILIES[chainFamily] ~= true
            and FLEXIBLE_CHAIN_FAMILIES[chainFamily] ~= true
            and finiteTank ~= true) then
        return nil, "ineligibleChain"
    end
    local stringKeys = {
        "combineId", "headerId", "rootVehicleId", "callDiscriminator",
        "inputFruitName", "outputFillName", "landUpdateToken",
        "compatibilityProfile"
    }
    local result = {active = true, reachCount = 0, inFlight = false}
    for _, key in ipairs(stringKeys) do
        local value = rawget(spec, key)
        if not text(value, state.policy.maxTextBytes) then
            return nil, "invalidContext"
        end
        result[key] = value
    end
    if not integer(rawget(spec, "serverSequence"), 0, MAX_IDENTIFIER)
        or not integer(rawget(spec, "farmId"), 0, MAX_IDENTIFIER)
        or not scalar(rawget(spec, "inputFruitType"), state.policy.maxTextBytes)
        or not scalar(rawget(spec, "outputFillType"), state.policy.maxTextBytes) then
        return nil, "invalidContext"
    end
    result.serverSequence = rawget(spec, "serverSequence")
    result.farmId = rawget(spec, "farmId")
    result.inputFruitType = rawget(spec, "inputFruitType")
    result.outputFillType = rawget(spec, "outputFillType")
    result.chainFamily = chainFamily
    result.finiteTank = finiteTank
    result.directDischarge = directDischarge
    result.reasons = copyReasons(rawget(spec, "reasons"), state.policy)
    if result.reasons == nil then return nil, "invalidContext" end
    result.compatibilityProfile = rawget(spec, "compatibilityProfile")
    return result
end

local function encoded(value)
    local stringValue
    if type(value) == "number" then
        stringValue = string.format("%.17g", value)
    else
        stringValue = tostring(value)
    end
    return type(value) .. ":" .. #stringValue .. ":" .. stringValue
end

local function replayIdentity(scope)
    return encoded(scope.rootVehicleId) .. encoded(scope.serverSequence)
        .. encoded(scope.callDiscriminator)
end

local function fingerprint(scope, litres)
    local parts = {
        scope.combineId, scope.headerId, scope.rootVehicleId,
        scope.serverSequence, scope.callDiscriminator, scope.farmId,
        scope.inputFruitType, scope.inputFruitName, scope.outputFillType,
        scope.outputFillName, scope.landUpdateToken,
        scope.compatibilityProfile, scope.chainFamily,
        scope.finiteTank and 1 or 0, scope.directDischarge and 1 or 0, litres
    }
    local result = {}
    for index, value in ipairs(parts) do result[index] = encoded(value) end
    for _, reason in ipairs(scope.reasons) do
        result[#result + 1] = encoded(reason)
    end
    return table.concat(result)
end

local function publishReplay(state, key, value)
    state.replay[key] = value
    state.replayOrder[#state.replayOrder + 1] = key
    while #state.replayOrder > state.policy.replayCapacity do
        local evicted = table.remove(state.replayOrder, 1)
        state.replay[evicted] = nil
    end
end

local function openImpl(state, spec)
    if not state.enabled then return nil, "observerDisabled" end
    if state.depth >= state.policy.maxDepth then
        abortAll(state, "scopeOverflow")
        state.enabled = false
        return nil, "scopeOverflow"
    end
    local scope, reason = copySpec(state, spec)
    if scope == nil then
        diagnostic(state, reason)
        return nil, reason
    end
    scope.owner = state.owner
    for index = 1, state.depth do
        local outer = state.stack[index]
        if outer.active and (outer.combineId == scope.combineId
            or outer.rootVehicleId == scope.rootVehicleId) then
            reject(state, outer, "nestedReach")
            reject(state, scope, "nestedReach")
        end
    end
    state.depth = state.depth + 1
    state.stack[state.depth] = scope
    return scope
end

local function beginImpl(state, scope, reach)
    if type(scope) ~= "table" or not rawequal(scope.owner, state.owner)
        or scope.active ~= true then
        return nil, "invalidScope"
    end
    if not closed(reach, REACH_KEYS) then
        reject(state, scope, "invalidReach")
        return nil, "invalidReach"
    end
    scope.reachCount = scope.reachCount + 1
    if scope.inFlight then
        reject(state, scope, "nestedReach")
    elseif scope.reachCount > 1 then
        reject(state, scope, "multipleReach")
    elseif not identityMatches(scope, reach) then
        reject(state, scope, "identityMismatch")
    end
    scope.inFlight = true
    return {owner = state.owner, scope = scope, active = true}
end

local function completeImpl(state, ticket, packed, failure)
    if type(ticket) ~= "table" or not rawequal(ticket.owner, state.owner)
        or ticket.active ~= true or type(ticket.scope) ~= "table" then
        return nil, "invalidTicket"
    end
    ticket.active = false
    local scope = ticket.scope
    ticket.scope = nil
    ticket.owner = nil
    if scope.active ~= true then return nil, "invalidScope" end
    scope.inFlight = false
    if failure ~= nil then
        reject(state, scope, failure)
        return nil, failure
    end
    if not plain(packed) or not integer(rawget(packed, "n"), 1, 64) then
        reject(state, scope, "returnContractDrift")
        return nil, "returnContractDrift"
    end
    local litres = rawget(packed, 1)
    if not finite(litres) then
        reject(state, scope, "nonFiniteOutput")
        return nil, "nonFiniteOutput"
    end
    if litres < 0 then
        reject(state, scope, "negativeOutput")
        return nil, "negativeOutput"
    end
    if litres > state.policy.maxHarvestedLitres then
        reject(state, scope, "outputOutOfBounds")
        return nil, "outputOutOfBounds"
    end
    scope.harvestedLitres = litres
    return true
end

local function closeImpl(state, scope, reason)
    if type(scope) ~= "table" or not rawequal(scope.owner, state.owner) then
        return nil, "invalidScope"
    end
    if scope.active ~= true then return nil, "invalidScope" end
    if state.depth == 0 or not rawequal(state.stack[state.depth], scope) then
        abortAll(state, "unwindMismatch")
        state.enabled = false
        return nil, "unwindMismatch"
    end
    state.stack[state.depth] = nil
    state.depth = state.depth - 1
    if reason ~= nil then reject(state, scope, reason) end
    if scope.inFlight then reject(state, scope, "reachIncomplete") end
    if scope.reachCount == 0 then reject(state, scope, "reachMissing") end
    if scope.reachCount > 1 then reject(state, scope, "multipleReach") end

    local rejection = scope.rejection
    local litres = scope.harvestedLitres
    if rejection ~= nil or litres == nil or litres == 0 then
        clearScope(scope)
        return nil, rejection
    end

    local key = replayIdentity(scope)
    local print = fingerprint(scope, litres)
    local prior = state.replay[key]
    if prior ~= nil then
        local duplicate = prior == print
        if not duplicate then diagnostic(state, "sequenceCollision", scope.rootVehicleId) end
        clearScope(scope)
        return nil, duplicate and "duplicateObservation" or "sequenceCollision"
    end

    local fact = {
        harvestedLitres = litres,
        combineId = scope.combineId,
        headerId = scope.headerId,
        rootVehicleId = scope.rootVehicleId,
        serverSequence = scope.serverSequence,
        callDiscriminator = scope.callDiscriminator,
        farmId = scope.farmId,
        inputFruitType = scope.inputFruitType,
        inputFruitName = scope.inputFruitName,
        outputFillType = scope.outputFillType,
        outputFillName = scope.outputFillName,
        landUpdateToken = scope.landUpdateToken,
        compatibilityProfile = scope.compatibilityProfile,
        chainFamily = scope.chainFamily,
        finiteTank = scope.finiteTank,
        directDischarge = scope.directDischarge,
        quality = "Observed",
        reasons = copyReasons(scope.reasons, state.policy)
    }
    publishReplay(state, key, print)
    clearScope(scope)
    return fact
end

local function guarded(state, implementation, ...)
    local ok, first, second = pcall(implementation, state, ...)
    if ok then return first, second end
    abortAll(state, "observerFailure")
    diagnostic(state, "observerFailure")
    return nil, "observerFailure"
end

local function getState(self)
    local state = PRIVATE[self]
    if state == nil then return nil, "invalidObserver" end
    return state
end

function HarvestObserver.new(policy, ...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    local normalized, reason = validatePolicy(policy)
    if normalized == nil then return nil, reason end
    local self = setmetatable({}, HarvestObserver)
    PRIVATE[self] = {
        owner = {}, enabled = true, policy = normalized, stack = {}, depth = 0,
        replay = {}, replayOrder = {}, diagnostics = {}, omittedDiagnostics = 0
    }
    return self
end

function HarvestObserver.openScope(self, spec, ...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    local state, reason = getState(self)
    if state == nil then return nil, reason end
    return guarded(state, openImpl, spec)
end

function HarvestObserver.beginReach(self, scope, reach, ...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    local state, reason = getState(self)
    if state == nil then return nil, reason end
    return guarded(state, beginImpl, scope, reach)
end

function HarvestObserver.completeReach(self, ticket, packed, ...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    local state, reason = getState(self)
    if state == nil then return nil, reason end
    return guarded(state, completeImpl, ticket, packed, nil)
end

function HarvestObserver.failReach(self, ticket, ...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    local state, reason = getState(self)
    if state == nil then return nil, reason end
    return guarded(state, completeImpl, ticket, nil, "superError")
end

function HarvestObserver.closeScope(self, scope, reason, ...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    local state, stateReason = getState(self)
    if state == nil then return nil, stateReason end
    if reason ~= nil and not LIFECYCLES[reason]
        and reason ~= "observerFailure" and reason ~= "callbackFailure" then
        return nil, "invalidReason"
    end
    return guarded(state, closeImpl, scope, reason)
end

function HarvestObserver.abort(self, lifecycle, ...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    local state, reason = getState(self)
    if state == nil then return nil, reason end
    if not LIFECYCLES[lifecycle] then return nil, "invalidLifecycle" end
    abortAll(state, lifecycle)
    if lifecycle == "save" or lifecycle == "unload" or lifecycle == "reset" then
        state.replay = {}
        state.replayOrder = {}
    end
    return true
end

function HarvestObserver.getDepth(self, ...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    local state, reason = getState(self)
    if state == nil then return nil, reason end
    return state.depth
end

function HarvestObserver.getDiagnostics(self, ...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    local state, reason = getState(self)
    if state == nil then return nil, reason end
    local rows = {}
    for index, row in ipairs(state.diagnostics) do
        rows[index] = {reason = row.reason, rootVehicleId = row.rootVehicleId}
    end
    return {rows = rows, omitted = state.omittedDiagnostics}
end

local function pack(...)
    return {n = select("#", ...), ...}
end

local unpackValues = unpack or table.unpack

-- Engine-neutral composition helper. The supplied pristine function is always
-- called exactly once; observer and callback failures never alter its returns.
function HarvestObserver.wrapPristine(observer, pristine, makeContext, onFact)
    if PRIVATE[observer] == nil or type(pristine) ~= "function"
        or type(makeContext) ~= "function" or type(onFact) ~= "function" then
        return nil, "invalidWrapperPort"
    end
    return function(...)
        local args = pack(...)
        local scope, reach
        local contextOk, spec, normalizedReach = pcall(
            makeContext, unpackValues(args, 1, args.n))
        if contextOk then
            scope = observer:openScope(spec)
            if scope ~= nil then
                reach = observer:beginReach(scope, normalizedReach)
            end
        end

        local returned = pack(pcall(function()
            return pristine(unpackValues(args, 1, args.n))
        end))
        for key in next, args do args[key] = nil end

        if returned[1] ~= true then
            local errorObject = returned[2]
            if reach ~= nil then observer:failReach(reach) end
            if scope ~= nil then observer:closeScope(scope, "observerFailure") end
            error(errorObject, 0)
        end

        if reach ~= nil then
            local packedReturns = {n = returned.n - 1}
            for index = 2, returned.n do
                packedReturns[index - 1] = returned[index]
            end
            observer:completeReach(reach, packedReturns)
        end
        if scope ~= nil then
            local fact = observer:closeScope(scope)
            if fact ~= nil then
                local callbackOk = pcall(onFact, fact)
                if not callbackOk then
                    local state = PRIVATE[observer]
                    diagnostic(state, "callbackFailure", fact.rootVehicleId)
                end
            end
        end
        return unpackValues(returned, 2, returned.n)
    end
end

FieldProfitabilityLedger.Adapters.HarvestObserver = HarvestObserver
return HarvestObserver
