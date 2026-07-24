-- Single-player application adapter. Dynamic WorkArea event
-- listeners remain class-wrapped, while FillUnit calls use a final vehicle-
-- type bridge registered after engine functions have been copied.

FieldProfitabilityLedger = FieldProfitabilityLedger or {}
FieldProfitabilityLedger.Runtime = FieldProfitabilityLedger.Runtime or {}

local ApplicationRuntimeAdapter = {}

local MAX_PENDING = 128
local MAX_FACTS_PER_UPDATE = 16
local MAX_SOWING_ROWS_PER_UPDATE = 16
local MAX_UPDATE_ROWS = 128
local MAX_DIAGNOSTICS = 64
local MAX_PHYSICAL = 1000000000
local PROFILE = "fs25-1.20-callable-unique"
local FACT_DISCRIMINATORS = {
    seed="i01", fertilizer="i02", lime="i03", herbicide="i04",
    manure="i05", slurry="i06", digestate="i07"
}

local classState = {
    installed = false,
    originals = nil,
    wrappers = nil,
    fillBridgeCount = 0,
    reason = nil
}
local active = nil

local SPRAY_CATEGORY = {
    FERTILIZER = "fertilizer",
    LIQUIDFERTILIZER = "fertilizer",
    LIME = "lime",
    HERBICIDE = "herbicide",
    MANURE = "manure",
    LIQUIDMANURE = "slurry",
    SLURRY = "slurry",
    DIGESTATE = "digestate"
}

local OPERATION_BY_CATEGORY = {
    seed = "seedingPlanting",
    fertilizer = "fertilizer",
    lime = "lime",
    herbicide = "herbicide",
    manure = "manure",
    slurry = "slurry",
    digestate = "digestate"
}

local function finite(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function integer(value, minimum, maximum)
    return finite(value) and value == math.floor(value)
        and value >= minimum and value <= maximum
end

local function token(value, maximum)
    if type(value) ~= "string" or #value == 0 or #value > maximum then
        return nil
    end
    for index = 1, #value do
        local byte = string.byte(value, index)
        if byte < 33 or byte > 126 then return nil end
    end
    return value
end

local function pack(...)
    return {n = select("#", ...), ...}
end

local unpackValues = unpack or table.unpack

local function returnedValues(invocation)
    local result = {n = invocation.n - 1}
    for index = 2, invocation.n do
        result[index - 1] = invocation[index]
    end
    return result
end

local function invoke(pristine, self, arguments)
    return pack(pcall(function()
        return pristine(self, unpackValues(arguments, 1, arguments.n))
    end))
end

local function replay(invocation)
    return unpackValues(invocation, 2, invocation.n)
end

local function method(object, name, ...)
    if type(object) ~= "table" then return nil end
    local found, callback = pcall(function() return object[name] end)
    if not found or type(callback) ~= "function" then return nil end
    local result = pack(pcall(callback, object, ...))
    if result[1] ~= true then return nil end
    return replay(result)
end

local function stableId(object)
    return token(method(object, "getUniqueId"), 64)
end

local function rootVehicle(object)
    return method(object, "getRootVehicle")
        or (type(object) == "table" and object.rootVehicle)
        or object
end

local function fillName(fillType)
    local manager = _G.g_fillTypeManager
    local value = method(manager, "getFillTypeNameByIndex", fillType)
    return token(value, 128)
end

local function toolUndefined()
    local values = _G.ToolType
    if type(values) ~= "table" then return nil end
    local value = values.UNDEFINED
    if type(value) == "string" or type(value) == "boolean" then return value end
    return finite(value) and value or nil
end

local function diagnose(state, code, context)
    local row = {code = type(code) == "string" and code or "applicationFailure",
        context = {}}
    if type(context) == "table" then
        for key, value in pairs(context) do
            if type(key) == "string" and (type(value) == "string"
                or type(value) == "number" or type(value) == "boolean") then
                row.context[key] = value
            end
        end
    end
    if #state.diagnostics < MAX_DIAGNOSTICS then
        state.diagnostics[#state.diagnostics + 1] = row
    else
        state.omittedDiagnostics = math.min(2147483647,
            state.omittedDiagnostics + 1)
    end
    local port = state.port.diagnose
    if type(port) == "function" then pcall(port, row.code, row.context) end
end

local function bindingsCurrent(family)
    if not classState.installed then return false end
    if family == "sowing" then
        return type(_G.SowingMachine) == "table"
            and SowingMachine.onEndWorkAreaProcessing
                == classState.wrappers.sowing
    elseif family == "spraying" then
        return type(_G.Sprayer) == "table"
            and Sprayer.onEndWorkAreaProcessing
                == classState.wrappers.spraying
    elseif family == "treePlanting" then
        return type(_G.TreePlanter) == "table"
            and TreePlanter.onUpdateTick == classState.wrappers.treePlanting
    end
    return classState.fillBridgeCount > 0
end

local function sequence(state)
    local ok, value = pcall(state.port.getSequence)
    if not ok or not integer(value, 1, 2147483647) then return nil end
    return value
end

local function authoritative(state, object)
    local ok, value = pcall(state.port.isAuthoritative, object)
    return ok and value == true
end

local function commonContext(state, consumer)
    if not authoritative(state, consumer) then return nil end
    local root = rootVehicle(consumer)
    local rootId = stableId(root)
    local consumerId = stableId(consumer)
    local updateSequence = sequence(state)
    if rootId == nil or consumerId == nil or updateSequence == nil then
        return nil
    end
    return {
        rootVehicleId = rootId,
        consumerToken = consumerId,
        serverSequence = updateSequence
    }
end

local function sowingCrop(spec, parameters)
    local fruitTypeId = type(parameters) == "table"
        and rawget(parameters, "seedsFruitType") or nil
    if not integer(fruitTypeId, 0, 2147483647) then
        fruitTypeId = type(spec) == "table"
            and rawget(spec, "selectedSeedFruitType") or nil
    end
    if not integer(fruitTypeId, 0, 2147483647) then return nil end
    local fruitType = method(_G.g_fruitTypeManager,
        "getFruitTypeNameByIndex", fruitTypeId)
    if token(fruitType, 128) == nil then return nil end
    return fruitType, fruitTypeId
end

local function sowingLandEvidence(state, consumer)
    local spec = type(consumer) == "table"
        and rawget(consumer, "spec_sowingMachine") or nil
    local parameters = type(spec) == "table"
        and rawget(spec, "workAreaParameters") or nil
    local areaPixels = type(parameters) == "table"
        and rawget(parameters, "lastChangedArea") or nil
    if not finite(areaPixels) or areaPixels <= 0
        or areaPixels > MAX_PHYSICAL then return nil end
    local context = commonContext(state, consumer)
    local fruitType, fruitTypeId = sowingCrop(spec, parameters)
    local farmId = method(consumer, "getActiveFarm")
        or method(consumer, "getOwnerFarmId")
    if context == nil or fruitType == nil
        or not integer(farmId, 0, 2147483647) then return nil end
    return {
        areaPixels = areaPixels,
        consumer = consumer,
        consumerToken = context.consumerToken,
        farmId = farmId,
        fruitType = fruitType,
        fruitTypeId = fruitTypeId,
        rootVehicleId = context.rootVehicleId,
        serverSequence = context.serverSequence
    }
end

local function observerSpec(state, family, consumer, source, unitIndex,
    fillType, name, farmId, context)
    local sourceId = stableId(source)
    local undefined = toolUndefined()
    if sourceId == nil or not integer(unitIndex, 1, 2147483647)
        or name == nil or undefined == nil then return nil end
    context.sourceToken = sourceId
    context.fillName = name
    context.fillTypeId = fillType
    context.family = family
    context.farmId = farmId
    context.consumerObject = consumer
    return {
        authority = true,
        family = family,
        consumerClass = family == "sowing" and SowingMachine or Sprayer,
        consumerObject = consumer,
        consumerToken = context.consumerToken,
        sourceObject = source,
        sourceToken = sourceId,
        unitIndex = unitIndex,
        fillType = fillType,
        fillName = name,
        farmId = farmId,
        toolType = undefined,
        expectedOrdinal = 1,
        compatibilityProfile = PROFILE,
        quality = "Observed",
        reasons = {}
    }
end

local function sowingScope(state, consumer)
    local spec = type(consumer) == "table" and consumer.spec_sowingMachine or nil
    local parameters = type(spec) == "table" and spec.workAreaParameters or nil
    if type(parameters) ~= "table"
        or not finite(parameters.lastChangedArea)
        or parameters.lastChangedArea <= 0
        or spec.consumableName ~= nil then return nil end
    local aiActive = method(consumer, "getIsAIActive")
    if type(aiActive) ~= "boolean" then return nil end
    local mission = _G.g_currentMission
    local missionInfo = type(mission) == "table" and mission.missionInfo or nil
    if aiActive and type(missionInfo) == "table"
        and missionInfo.helperBuySeeds == true then return nil end
    local source = parameters.seedsVehicle
    local unitIndex = parameters.seedsVehicleFillUnitIndex
    local fillType = method(source, "getFillUnitFillType", unitIndex)
    local name = fillName(fillType)
    local farmId = method(consumer, "getOwnerFarmId")
    local context = commonContext(state, consumer)
    if context == nil or farmId == nil then return nil end
    context.category = "seed"
    context.operationType = "seedingPlanting"
    return observerSpec(state, "sowing", consumer, source, unitIndex,
        fillType, name, farmId, context), context
end

local function sprayingScope(state, consumer)
    local spec = type(consumer) == "table" and consumer.spec_sprayer or nil
    local parameters = type(spec) == "table" and spec.workAreaParameters or nil
    if type(parameters) ~= "table" or parameters.isActive ~= true
        or not finite(parameters.usage) or parameters.usage <= 0 then return nil end
    local source = parameters.sprayVehicle
    local unitIndex = parameters.sprayVehicleFillUnitIndex
    local fillType = parameters.sprayFillType
    local name = fillName(fillType)
    local category = name ~= nil and SPRAY_CATEGORY[string.upper(name)] or nil
    local farmId = method(consumer, "getOwnerFarmId")
    local context = commonContext(state, consumer)
    if category == nil or context == nil or farmId == nil then return nil end
    context.category = category
    context.operationType = OPERATION_BY_CATEGORY[category]
    -- A fertilizing sowing machine (for example the Horsch Avatar 12.25 SD)
    -- consumes fertilizer through Sprayer while publishing only one generic
    -- WorkArea row: sowingMachine. Retain that proven specialization link so
    -- the physical fertilizer fact can bind to the accepted sowing operation
    -- when no separate fertilizer WorkArea exists.
    if category == "fertilizer"
        and type(rawget(consumer, "spec_sowingMachine")) == "table" then
        context.acceptedOperationFallback = "seedingPlanting"
    end
    return observerSpec(state, "spraying", consumer, source, unitIndex,
        fillType, name, farmId, context), context
end

local function pendingKey(rootVehicleId, updateSequence)
    return rootVehicleId .. "\31" .. tostring(updateSequence)
end

local evictPending

local function prunePendingOrder(state)
    local order = state.pendingOrder
    local head = state.pendingHead
    while head <= #order and state.pending[order[head]] == nil do
        head = head + 1
    end
    local tail = #order
    local span = head <= tail and tail - head + 1 or 0
    if head > MAX_PENDING * 2 or span > MAX_PENDING * 2 then
        local compact, retained = {}, {}
        -- A live oldest bucket can pin resolved keys behind it, so advancing
        -- only the head is insufficient.  Retain each currently-live key's
        -- newest insertion, which also preserves FIFO order after a key is
        -- discarded and later staged again.
        for index = tail, head, -1 do
            local key = order[index]
            if state.pending[key] ~= nil and not retained[key] then
                retained[key] = true
                compact[#compact + 1] = key
            end
        end
        for left = 1, math.floor(#compact / 2) do
            local right = #compact - left + 1
            compact[left], compact[right] = compact[right], compact[left]
        end
        state.pendingOrder = compact
        state.pendingHead = 1
    else
        state.pendingHead = head
    end
end

local function pendingBucket(state, rootVehicleId, updateSequence)
    local key = pendingKey(rootVehicleId, updateSequence)
    local bucket = state.pending[key]
    if bucket ~= nil then return bucket, key end
    prunePendingOrder(state)
    if not evictPending(state) then return nil, key end
    bucket = {
        rootVehicleId = rootVehicleId,
        serverSequence = updateSequence,
        facts = {},
        factCount = 0,
        sowing = {},
        sowingCount = 0
    }
    state.pending[key] = bucket
    state.pendingOrder[#state.pendingOrder + 1] = key
    state.pendingCount = state.pendingCount + 1
    return bucket, key
end

local function removePending(state, key)
    if state.pending[key] ~= nil then
        state.pending[key] = nil
        state.pendingCount = math.max(0, state.pendingCount - 1)
    end
end

evictPending = function(state)
    while state.pendingCount >= MAX_PENDING do
        prunePendingOrder(state)
        local key = state.pendingOrder[state.pendingHead]
        if key == nil then return false end
        state.pendingHead = state.pendingHead + 1
        if state.pending[key] ~= nil then
            removePending(state, key)
            diagnose(state, "applicationPendingEvicted", {})
            return true
        end
    end
    return true
end

local function stageFact(state, context, fact)
    if active ~= state or type(fact) ~= "table"
        or not finite(fact.appliedLitres) or fact.appliedLitres <= 0
        or fact.appliedLitres > MAX_PHYSICAL then return nil end
    local bucket, key = pendingBucket(
        state, context.rootVehicleId, context.serverSequence)
    if bucket == nil then return nil end
    local entry = bucket.facts[context.category]
    if entry == nil then
        if bucket.factCount >= MAX_FACTS_PER_UPDATE then return nil end
        entry = {
            amount = 0,
            category = context.category,
            compatibilityProfile = fact.compatibilityProfile,
            consumerCount = 0,
            consumers = {},
            consumerObjects = {},
            family = context.family,
            farmId = context.farmId,
            fillName = context.fillName,
            fillTypeId = context.fillTypeId,
            operationType = context.operationType,
            acceptedOperationFallback = context.acceptedOperationFallback,
            sourceCount = 0,
            sources = {}
        }
        bucket.facts[context.category] = entry
        bucket.factCount = bucket.factCount + 1
    elseif entry.family ~= context.family or entry.farmId ~= context.farmId
        or entry.operationType ~= context.operationType then
        removePending(state, key)
        return nil
    end
    local amount = entry.amount + fact.appliedLitres
    if not finite(amount) or amount > MAX_PHYSICAL then
        removePending(state, key)
        diagnose(state, "applicationAmountOutOfBounds", {
            rootVehicleId = context.rootVehicleId,
            serverSequence = context.serverSequence
        })
        return nil
    end
    entry.amount = amount
    if not entry.consumers[context.consumerToken] then
        entry.consumers[context.consumerToken] = true
        entry.consumerObjects[context.consumerToken] = context.consumerObject
        entry.consumerCount = entry.consumerCount + 1
    end
    if not entry.sources[context.sourceToken] then
        entry.sources[context.sourceToken] = true
        entry.sourceCount = entry.sourceCount + 1
    end
    if entry.fillName ~= context.fillName then
        entry.fillName = "multiple"
        entry.fillTypeId = nil
    elseif entry.fillTypeId ~= context.fillTypeId then
        entry.fillTypeId = nil
    end
    return true
end

local function stageSowingLand(state, evidence)
    if active ~= state or type(evidence) ~= "table" then return nil end
    local bucket = pendingBucket(
        state, evidence.rootVehicleId, evidence.serverSequence)
    if bucket == nil then return nil end
    local entry = bucket.sowing[evidence.consumerToken]
    if entry == nil then
        if bucket.sowingCount >= MAX_SOWING_ROWS_PER_UPDATE then return nil end
        entry = evidence
        bucket.sowing[evidence.consumerToken] = entry
        bucket.sowingCount = bucket.sowingCount + 1
        return true
    end
    if entry.fruitType ~= evidence.fruitType
        or entry.fruitTypeId ~= evidence.fruitTypeId
        or entry.farmId ~= evidence.farmId
        or not rawequal(entry.consumer, evidence.consumer) then return nil end
    local amount = entry.areaPixels + evidence.areaPixels
    if not finite(amount) or amount > MAX_PHYSICAL then return nil end
    entry.areaPixels = amount
    return true
end

local function endWrapper(pristine, family)
    return function(self, ...)
        local state = active
        if state == nil or state.disabled then return pristine(self, ...) end
        if not bindingsCurrent(family) or not bindingsCurrent("fill") then
            state.disabled = true
            state.observer:abortLifecycle("reset")
            diagnose(state, "laterClassReplacement", {family = family})
            return pristine(self, ...)
        end
        local landEvidence = family == "sowing"
            and sowingLandEvidence(state, self) or nil
        local spec, context
        if family == "sowing" then
            spec, context = sowingScope(state, self)
        else
            spec, context = sprayingScope(state, self)
        end
        if spec == nil and landEvidence == nil then return pristine(self, ...) end
        if spec == nil then
            local invocation = invoke(pristine, self, pack(...))
            if invocation[1] ~= true then error(invocation[2], 0) end
            if not stageSowingLand(state, landEvidence) then
                diagnose(state, "applicationSowingLandDiscarded", {
                    rootVehicleId = landEvidence.rootVehicleId,
                    serverSequence = landEvidence.serverSequence
                })
            end
            return replay(invocation)
        end
        local scope, scopeReason = state.observer:openScope(spec)
        if scope == nil then
            diagnose(state, scopeReason or "applicationScopeRejected",
                {family = family})
            local invocation = invoke(pristine, self, pack(...))
            if invocation[1] ~= true then error(invocation[2], 0) end
            if landEvidence ~= nil
                and not stageSowingLand(state, landEvidence) then
                diagnose(state, "applicationSowingLandDiscarded", {
                    rootVehicleId = landEvidence.rootVehicleId,
                    serverSequence = landEvidence.serverSequence
                })
            end
            return replay(invocation)
        end
        local invocation = invoke(pristine, self, pack(...))
        if invocation[1] ~= true then
            state.observer:closeScope(scope, "endError")
            error(invocation[2], 0)
        end
        local fact, factReason = state.observer:closeScope(scope)
        if landEvidence ~= nil and not stageSowingLand(state, landEvidence) then
            diagnose(state, "applicationSowingLandDiscarded", {
                rootVehicleId = landEvidence.rootVehicleId,
                serverSequence = landEvidence.serverSequence
            })
        end
        if fact ~= nil then
            if not stageFact(state, context, fact) then
                diagnose(state, "applicationFactDiscarded", {
                    category = context.category,
                    rootVehicleId = context.rootVehicleId,
                    serverSequence = context.serverSequence
                })
            end
        elseif factReason ~= nil then
            diagnose(state, factReason, {family = family})
        end
        return replay(invocation)
    end
end

local function treePlantingContext(state, consumer)
    if not authoritative(state, consumer) then return nil end
    local spec = type(consumer) == "table"
        and rawget(consumer, "spec_treePlanter") or nil
    local workSpec = type(consumer) == "table"
        and rawget(consumer, "spec_workArea") or nil
    local unitIndex = type(spec) == "table"
        and rawget(spec, "fillUnitIndex") or nil
    if type(workSpec) ~= "table"
        or not integer(unitIndex, 1, 2147483647) then return nil end
    local fillType = method(consumer, "getFillUnitFillType", unitIndex)
    local name = fillName(fillType)
    local before = method(consumer, "getFillUnitFillLevel", unitIndex)
    local context = commonContext(state, consumer)
    local farmId = method(consumer, "getOwnerFarmId")
    if type(name) ~= "string" or string.upper(name) ~= "POPLAR"
        or not finite(before) or before < 0 or before > MAX_PHYSICAL
        or context == nil or not integer(farmId, 0, 2147483647) then
        return nil
    end
    context.category = "seed"
    context.operationType = "seedingPlanting"
    context.sourceToken = context.consumerToken
    context.fillName = name
    context.fillTypeId = fillType
    return {
        before = before,
        unitIndex = unitIndex,
        workSpec = workSpec,
        context = context
    }
end

local function treePlantingWrapper(pristine)
    return function(self, ...)
        local state = active
        if state == nil or state.disabled then return pristine(self, ...) end
        if not bindingsCurrent("treePlanting") then
            state.disabled = true
            state.observer:abortLifecycle("reset")
            diagnose(state, "laterClassReplacement", {
                family = "treePlanting"
            })
            return pristine(self, ...)
        end
        local sample = treePlantingContext(state, self)
        local invocation = invoke(pristine, self, pack(...))
        if invocation[1] ~= true then error(invocation[2], 0) end
        if sample ~= nil then
            local area = rawget(sample.workSpec, "lastWorkedArea")
            local after = method(self, "getFillUnitFillLevel",
                sample.unitIndex)
            local amount = finite(after) and sample.before - after or nil
            if finite(area) and area > 0 and area <= MAX_PHYSICAL
                and finite(amount) and amount > 0
                and amount <= MAX_PHYSICAL then
                local fact = {
                    appliedLitres = amount,
                    compatibilityProfile =
                        "fs25-1.20-tree-planter-poplar"
                }
                if not stageFact(state, sample.context, fact) then
                    diagnose(state, "applicationFactDiscarded", {
                        category = "seed",
                        rootVehicleId = sample.context.rootVehicleId,
                        serverSequence = sample.context.serverSequence
                    })
                end
            end
        end
        return replay(invocation)
    end
end

function ApplicationRuntimeAdapter.observeFillUnitCall(self, pristine, ...)
    local state = active
    if state == nil or state.disabled
        or not state.observer:hasOpenScopes() then return pristine(self, ...) end
    local arguments = pack(...)
    local ticket = state.observer:beginFillCall({
        sourceObject = self,
        farmId = arguments[1],
        unitIndex = arguments[2],
        delta = arguments[3],
        fillType = arguments[4],
        toolType = arguments[5]
    })
    local invocation = invoke(pristine, self, arguments)
    if ticket ~= nil then
        if invocation[1] == true then
            state.observer:completeFillCall(ticket,
                returnedValues(invocation))
        else
            state.observer:failFillCall(ticket)
        end
    end
    if invocation[1] ~= true then error(invocation[2], 0) end
    return replay(invocation)
end


function ApplicationRuntimeAdapter.installClassWrappers(...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    if classState.installed then return true, false end
    local sowing = type(_G.SowingMachine) == "table"
        and SowingMachine.onEndWorkAreaProcessing or nil
    local spraying = type(_G.Sprayer) == "table"
        and Sprayer.onEndWorkAreaProcessing or nil
    local fill = type(_G.FillUnit) == "table"
        and FillUnit.addFillUnitFillLevel or nil
    local treePlanting = type(_G.TreePlanter) == "table"
        and TreePlanter.onUpdateTick or nil
    if type(sowing) ~= "function" or type(spraying) ~= "function"
        or type(fill) ~= "function" or type(treePlanting) ~= "function" then
        classState.reason = "applicationClassUnavailable"
        return nil, classState.reason
    end
    if sowing == spraying or sowing == fill or spraying == fill
        or treePlanting == sowing or treePlanting == spraying
        or treePlanting == fill then
        classState.reason = "applicationClassIdentityCollision"
        return nil, classState.reason
    end
    local wrappers = {
        sowing = endWrapper(sowing, "sowing"),
        spraying = endWrapper(spraying, "spraying"),
        treePlanting = treePlantingWrapper(treePlanting)
    }
    -- Assignment occurs only after every required class pointer is captured.
    SowingMachine.onEndWorkAreaProcessing = wrappers.sowing
    Sprayer.onEndWorkAreaProcessing = wrappers.spraying
    TreePlanter.onUpdateTick = wrappers.treePlanting
    classState.originals = {sowing = sowing, spraying = spraying,
        fill = fill, treePlanting = treePlanting}
    classState.wrappers = wrappers
    classState.installed = true
    classState.reason = nil
    return true, true
end

function ApplicationRuntimeAdapter.registerFillUnitBridge(...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    if not classState.installed then
        return nil, classState.reason or "applicationClassUnavailable"
    end
    classState.fillBridgeCount = classState.fillBridgeCount + 1
    return true, classState.fillBridgeCount
end

function ApplicationRuntimeAdapter.activate(port, ...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    if active ~= nil then
        if rawequal(active.port, port) then return true, false end
        return nil, "applicationAlreadyActive"
    end
    if type(port) ~= "table" or getmetatable(port) ~= nil
        or type(port.isSinglePlayer) ~= "function"
        or type(port.isAuthoritative) ~= "function"
        or type(port.getSequence) ~= "function"
        or type(port.acceptObservedFact) ~= "function"
        or type(port.getApplicationAttributionSnapshots) ~= "function"
        or type(port.getSowingAttributionSnapshots) ~= "function"
        or type(port.resolveAttribution) ~= "function"
        or type(port.areaToHa) ~= "function" then
        return nil, "invalidApplicationPort"
    end
    local ok, supported = pcall(port.isSinglePlayer)
    if not ok or supported ~= true then return nil, "unsupportedRole" end
    if not classState.installed or not bindingsCurrent("sowing")
        or not bindingsCurrent("spraying")
        or not bindingsCurrent("treePlanting")
        or not bindingsCurrent("fill") then
        return nil, classState.reason or "applicationBindingsUnavailable"
    end
    local adapters = FieldProfitabilityLedger.Adapters
    local observerClass = type(adapters) == "table"
        and adapters.ApplicationObserver or nil
    if type(observerClass) ~= "table" or type(observerClass.new) ~= "function" then
        return nil, "applicationObserverUnavailable"
    end
    local observer, reason = observerClass.new({
        maxDepth = 16,
        maxAppliedLitres = MAX_PHYSICAL,
        diagnosticCapacity = 64,
        maxReasons = 16,
        maxTextBytes = 256
    }, {
        copyToken = function(_, value)
            return token(value, 64)
        end,
        equalToken = function(_, left, right) return left == right end,
        resolveSourceToken = function(source) return stableId(source) end
    })
    if observer == nil then return nil, reason end
    active = {
        port = port,
        observer = observer,
        pending = {},
        pendingOrder = {},
        pendingHead = 1,
        pendingCount = 0,
        diagnostics = {},
        omittedDiagnostics = 0,
        disabled = false
    }
    return true, true
end

local function attributionIdentity(value)
    return table.concat({
        tostring(value.kind), tostring(value.landKey), tostring(value.farmId),
        tostring(value.farmlandId), tostring(value.fieldId),
        tostring(value.fieldKind), tostring(value.cycleAreaHa)
    }, "\31")
end

local function detachedSowingSnapshot(state, consumer)
    local called, snapshots, reason = pcall(
        state.port.getSowingAttributionSnapshots, consumer)
    if not called or type(snapshots) ~= "table" or #snapshots == 0 then
        return nil, type(reason) == "string" and reason
            or "applicationSowingSnapshotUnavailable"
    end
    local identity, firstSnapshot, firstAttribution = nil, nil, nil
    for index = 1, #snapshots do
        local resolved, attribution, attributionReason = pcall(
            state.port.resolveAttribution, snapshots[index])
        if not resolved or type(attribution) ~= "table"
            or (attribution.kind ~= "baseField"
                and attribution.kind ~= "parcel") then
            return nil, type(attributionReason) == "string"
                and attributionReason or "applicationSowingAttributionRejected"
        end
        local current = attributionIdentity(attribution)
        if identity == nil then
            identity = current
            firstSnapshot = snapshots[index]
            firstAttribution = attribution
        elseif identity ~= current then
            return nil, "applicationSowingDistinctLand"
        end
    end
    return firstSnapshot, firstAttribution
end

local function releaseFactConsumers(bucket)
    for _, fact in pairs(bucket.facts or {}) do
        fact.consumerObjects = {}
    end
end

local function detachedApplicationAttribution(state, root, fact)
    if fact.family ~= "spraying" or type(fact.consumerObjects) ~= "table" then
        return nil, "applicationFactOnlyUnsupported"
    end
    local consumers = {}
    for consumerToken, consumer in pairs(fact.consumerObjects) do
        consumers[#consumers + 1] = {
            token = consumerToken,
            consumer = consumer
        }
    end
    table.sort(consumers, function(left, right)
        return left.token < right.token
    end)
    fact.consumerObjects = {}
    if #consumers == 0 then
        return nil, "applicationSnapshotUnavailable"
    end
    local identity, firstAttribution = nil, nil
    for _, descriptor in ipairs(consumers) do
        local consumer = descriptor.consumer
        if not rawequal(rootVehicle(consumer), root) then
            return nil, "applicationFactOnlyRootMismatch"
        end
        local called, snapshots, reason = pcall(
            state.port.getApplicationAttributionSnapshots, consumer)
        descriptor.consumer = nil
        if not called or type(snapshots) ~= "table" or #snapshots == 0 then
            return nil, type(reason) == "string" and reason
                or "applicationSnapshotUnavailable"
        end
        for index = 1, #snapshots do
            local resolved, attribution, attributionReason = pcall(
                state.port.resolveAttribution, snapshots[index])
            if not resolved or type(attribution) ~= "table"
                or (attribution.kind ~= "baseField"
                    and attribution.kind ~= "parcel") then
                return nil, type(attributionReason) == "string"
                    and attributionReason
                    or "applicationFactOnlyAttributionRejected"
            end
            if attribution.farmId ~= fact.farmId then
                return nil, "applicationFactOnlyFarmMismatch"
            end
            local current = attributionIdentity(attribution)
            if identity == nil then
                identity = current
                firstAttribution = attribution
            elseif identity ~= current then
                return nil, "applicationFactOnlyDistinctLand"
            end
        end
    end
    return firstAttribution
end

local function sowingDiscriminator(consumerToken)
    local hash = 0
    for index = 1, #consumerToken do
        hash = (hash * 131 + string.byte(consumerToken, index)) % 2147483647
    end
    return string.format("app-sow-%08x", hash)
end

function ApplicationRuntimeAdapter.augmentUpdate(root, update, ...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    local state = active
    if state == nil then return update end
    if type(update) ~= "table" or getmetatable(update) ~= nil
        or token(update.rootVehicleId, 64) == nil
        or not integer(update.serverSequence, 1, 2147483647)
        or type(update.rows) ~= "table" then
        return nil, "invalidApplicationUpdate"
    end
    local key = pendingKey(update.rootVehicleId, update.serverSequence)
    local bucket = state.pending[key]
    if bucket == nil then return update end

    if bucket.sowingCount > 0 and not bucket.sowingAugmented then
        local hasSowingRow = false
        for index = 1, #update.rows do
            local row = update.rows[index]
            if type(row) == "table"
                and row.operationType == "seedingPlanting" then
                hasSowingRow = true
                break
            end
        end
        local consumers = {}
        for consumerToken in pairs(bucket.sowing) do
            consumers[#consumers + 1] = consumerToken
        end
        table.sort(consumers)
        local rows = {}
        local cropName, cropId = nil, nil
        for _, consumerToken in ipairs(consumers) do
            local entry = bucket.sowing[consumerToken]
            if not rawequal(rootVehicle(entry.consumer), root) then
                removePending(state, key)
                return nil, "applicationSowingRootMismatch"
            end
            if cropName == nil then
                cropName, cropId = entry.fruitType, entry.fruitTypeId
            elseif cropName ~= entry.fruitType
                or cropId ~= entry.fruitTypeId then
                removePending(state, key)
                return nil, "applicationSowingCropCollision"
            end
            if not hasSowingRow then
                local snapshot, attributionOrReason = detachedSowingSnapshot(
                    state, entry.consumer)
                entry.consumer = nil
                if snapshot == nil then
                    removePending(state, key)
                    diagnose(state, attributionOrReason, {
                        rootVehicleId=bucket.rootVehicleId,
                        serverSequence=bucket.serverSequence
                    })
                    return nil, attributionOrReason
                end
                if attributionOrReason.farmId ~= entry.farmId then
                    removePending(state, key)
                    return nil, "applicationSowingFarmMismatch"
                end
                local converted, areaHa, areaReason = pcall(
                    state.port.areaToHa, entry.areaPixels)
                if not converted or not finite(areaHa) or areaHa <= 0 then
                    removePending(state, key)
                    return nil, type(areaReason) == "string" and areaReason
                        or "applicationSowingAreaRejected"
                end
                rows[#rows + 1] = {
                    attributionSnapshot = snapshot,
                    changedAreaHa = areaHa,
                    observationDiscriminator = sowingDiscriminator(consumerToken),
                    operationType = "seedingPlanting",
                    workAreaType = "sowingmachine"
                }
            else
                entry.consumer = nil
            end
        end
        if #update.rows + #rows > MAX_UPDATE_ROWS then
            removePending(state, key)
            return nil, "tooManyRows"
        end
        if cropName ~= nil then
            if update.fruitType ~= nil and update.fruitType ~= "unknown"
                and (update.fruitType ~= cropName
                    or update.fruitTypeId ~= cropId) then
                removePending(state, key)
                return nil, "applicationSowingCropCollision"
            end
            update.fruitType = cropName
            update.fruitTypeId = cropId
        end
        for _, row in ipairs(rows) do update.rows[#update.rows + 1] = row end
        bucket.sowingAugmented = true
    end

    local hasPositiveRow = false
    for index = 1, #update.rows do
        local row = update.rows[index]
        if type(row) == "table" and finite(row.changedAreaHa)
            and row.changedAreaHa > 0
            and string.lower(tostring(row.workAreaType)) ~= "auxiliary" then
            hasPositiveRow = true
            break
        end
    end
    if hasPositiveRow or bucket.factCount == 0 then
        releaseFactConsumers(bucket)
        return update
    end
    if bucket.factOnlyPrepared then return update end
    if bucket.factCount ~= 1 or rawget(update, "factOnly") ~= nil then
        releaseFactConsumers(bucket)
        removePending(state, key)
        diagnose(state, "applicationFactOnlyAmbiguous", {
            rootVehicleId=bucket.rootVehicleId,
            serverSequence=bucket.serverSequence,
            factCount=bucket.factCount
        })
        return update
    end
    local category, fact = next(bucket.facts)
    local attribution, attributionReason = detachedApplicationAttribution(
        state, root, fact)
    if attribution == nil then
        removePending(state, key)
        diagnose(state, attributionReason, {
            category=category,
            rootVehicleId=bucket.rootVehicleId,
            serverSequence=bucket.serverSequence
        })
        return update
    end
    local discriminator = FACT_DISCRIMINATORS[category]
    if discriminator == nil then
        removePending(state, key)
        diagnose(state, "applicationCategoryUnsupported", {
            category=category,
            rootVehicleId=bucket.rootVehicleId,
            serverSequence=bucket.serverSequence
        })
        return update
    end
    update.factOnly = {
        attribution = attribution,
        observationDiscriminator = discriminator,
        operationType = fact.operationType,
        recordType = "input",
        category = category,
        amount = fact.amount,
        unit = "litres",
        qualityClass = "Partial",
        reasons = {"zeroChangedArea"},
        metadata = {
            compatibilityProfile = fact.compatibilityProfile,
            consumerCount = fact.consumerCount,
            fillName = fact.fillName,
            fillTypeId = fact.fillTypeId,
            sourceCount = fact.sourceCount
        }
    }
    bucket.factOnlyPrepared = true
    return update
end

function ApplicationRuntimeAdapter.onAcceptedUpdate(update, ...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    local state = active
    if state == nil then return true, 0 end
    if type(update) ~= "table" or getmetatable(update) ~= nil
        or token(update.rootVehicleId, 64) == nil
        or not integer(update.serverSequence, 1, 2147483647)
        or type(update.operations) ~= "table" then
        return nil, "invalidAcceptedUpdate"
    end
    local key = pendingKey(update.rootVehicleId, update.serverSequence)
    local bucket = state.pending[key]
    if bucket == nil then return true, 0 end
    removePending(state, key)
    if update.factOnly == true then
        return true, bucket.factOnlyPrepared and 1 or 0
    end
    local operations = {}
    for index = 1, #update.operations do
        local operation = update.operations[index]
        if type(operation) == "table"
            and token(operation.operationType, 64) ~= nil
            and token(operation.observationDiscriminator, 64) ~= nil then
            operations[operation.operationType] =
                operation.observationDiscriminator
        end
    end
    local categories = {}
    for category in pairs(bucket.facts) do categories[#categories + 1] = category end
    table.sort(categories)
    local accepted = 0
    for _, category in ipairs(categories) do
        local fact = bucket.facts[category]
        local operationDiscriminator = operations[fact.operationType]
        if operationDiscriminator == nil
            and fact.acceptedOperationFallback ~= nil then
            operationDiscriminator = operations[fact.acceptedOperationFallback]
        end
        if operationDiscriminator == nil then
            diagnose(state, "applicationAcceptedLandMissing", {
                category = category,
                rootVehicleId = bucket.rootVehicleId,
                serverSequence = bucket.serverSequence
            })
        else
            local factDiscriminator = FACT_DISCRIMINATORS[category]
            if factDiscriminator == nil then
                diagnose(state, "applicationCategoryUnsupported", {
                    category = category,
                    rootVehicleId = bucket.rootVehicleId,
                    serverSequence = bucket.serverSequence
                })
            else
                local called, record, reason = pcall(state.port.acceptObservedFact, {
                rootVehicleId = bucket.rootVehicleId,
                serverSequence = bucket.serverSequence,
                observationDiscriminator = factDiscriminator,
                operationObservationDiscriminator = operationDiscriminator,
                recordType = "input",
                category = category,
                amount = fact.amount,
                unit = "litres",
                qualityClass = "Complete",
                reasons = {},
                metadata = {
                    compatibilityProfile = fact.compatibilityProfile,
                    consumerCount = fact.consumerCount,
                    fillName = fact.fillName,
                    fillTypeId = fact.fillTypeId,
                    sourceCount = fact.sourceCount
                }
                })
                if called and type(record) == "table" then
                    accepted = accepted + 1
                else
                    diagnose(state, type(reason) == "string" and reason
                        or "applicationFactRejected", {
                        category = category,
                        rootVehicleId = bucket.rootVehicleId,
                        serverSequence = bucket.serverSequence
                    })
                end
            end
        end
    end
    return true, accepted
end

function ApplicationRuntimeAdapter.discardUpdate(
    rootVehicleId, serverSequence, reason, ...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    local state = active
    if state == nil then return true, false end
    local root = token(rootVehicleId, 64)
    if root == nil or not integer(serverSequence, 1, 2147483647)
        or (reason ~= nil and type(reason) ~= "string") then
        return nil, "invalidApplicationUpdate"
    end
    local key = pendingKey(root, serverSequence)
    if state.pending[key] == nil then return true, false end
    removePending(state, key)
    diagnose(state, "applicationUpdateDiscarded", {
        rootVehicleId=root,
        serverSequence=serverSequence,
        reason=reason or "updateDiscarded"
    })
    return true, true
end

function ApplicationRuntimeAdapter.abortLifecycle(lifecycle, ...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    local state = active
    if state == nil then return true, false end
    local ok = state.observer:abortLifecycle(lifecycle)
    if ok == nil then return nil, "applicationLifecycleRejected" end
    state.pending = {}
    state.pendingOrder = {}
    state.pendingHead = 1
    state.pendingCount = 0
    if lifecycle == "unload" then active = nil end
    return true, true
end

function ApplicationRuntimeAdapter.getStatus(...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    local state = active
    local diagnostics = {}
    if state ~= nil then
        for index, row in ipairs(state.diagnostics) do
            local context = {}
            for key, value in pairs(row.context) do context[key] = value end
            diagnostics[index] = {code = row.code, context = context}
        end
    end
    return {
        active = state ~= nil,
        bindingsInstalled = classState.installed
            and bindingsCurrent("sowing") and bindingsCurrent("spraying")
            and bindingsCurrent("treePlanting") and bindingsCurrent("fill"),
        classContractInstalled = classState.installed,
        fillBridgeCount = classState.fillBridgeCount,
        disabled = state ~= nil and state.disabled or false,
        pendingUpdates = state ~= nil and state.pendingCount or 0,
        diagnostics = diagnostics,
        omittedDiagnostics = state ~= nil and state.omittedDiagnostics or 0,
        reason = classState.reason
    }
end

FieldProfitabilityLedger.Runtime.ApplicationRuntimeAdapter =
    ApplicationRuntimeAdapter

return ApplicationRuntimeAdapter
