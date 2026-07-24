-- Single-player base field-crop harvest adapter. A final vehicle-
-- type bridge is registered after Combine has copied its functions, and the
-- first authoritative producer output is joined only through the same sealed
-- WorkArea update. Grass/forage and post-harvest chains remain out of scope.

FieldProfitabilityLedger = FieldProfitabilityLedger or {}
FieldProfitabilityLedger.Runtime = FieldProfitabilityLedger.Runtime or {}

local HarvestRuntimeAdapter = {}

local MAX_PHYSICAL = 1000000000
local MAX_PENDING = 128
local MAX_ENTRIES = 16
local MAX_DIAGNOSTICS = 64
local PROFILE = "fs25-1.20-base-field-crops-v1"

local CROP_CONTRACTS = {
    WHEAT={output="WHEAT", family="conventionalTank"},
    BARLEY={output="BARLEY", family="conventionalTank"},
    CANOLA={output="CANOLA", family="conventionalTank"},
    OAT={output="OAT", family="conventionalTank"},
    MAIZE={output="MAIZE", family="maizeHeaderTank"},
    SUNFLOWER={output="SUNFLOWER", family="maizeHeaderTank"},
    SOYBEAN={output="SOYBEAN", family="conventionalTank"},
    POTATO={output="POTATO", family="rootTank"},
    RICE={output="RICE", family="integratedTank"},
    RICELONGGRAIN={output="RICELONGGRAIN", family="conventionalTank"},
    SUGARBEET={output="SUGARBEET", family="rootTank"},
    SUGARCANE={output="SUGARCANE", family="directDischarge"},
    COTTON={output="COTTON", family="cottonBuffer"},
    SORGHUM={output="SORGHUM", family="conventionalTank"},
    GRAPE={output="GRAPE", family="vineTank"},
    OLIVE={output="OLIVE", family="vineTank"},
    POPLAR={output="WOODCHIPS", family="convertedOutput"},
    BEETROOT={output="BEETROOT", family="topLiftingDirectDischarge"},
    CARROT={output="CARROT", family="topLiftingDirectDischarge"},
    PARSNIP={output="PARSNIP", family="topLiftingDirectDischarge"},
    GREENBEAN={output="GREENBEAN", family="integratedTank"},
    PEA={output="PEA", family="integratedTank"},
    SPINACH={output="SPINACH", family="integratedTank"}
}

local classState = {installed=false, original=nil, bridgeCount=0, reason=nil}
local active = nil

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
    return {n=select("#", ...), ...}
end

local unpackValues = unpack or table.unpack

local function invoke(pristine, self, arguments)
    return pack(pcall(function()
        return pristine(self, unpackValues(arguments, 1, arguments.n))
    end))
end

local function replay(invocation)
    return unpackValues(invocation, 2, invocation.n)
end

local function returnedValues(invocation)
    local result = {n=invocation.n - 1}
    for index = 2, invocation.n do result[index - 1] = invocation[index] end
    return result
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

local function pendingKey(rootVehicleId, updateSequence)
    return rootVehicleId .. "\31" .. tostring(updateSequence)
end

local function diagnose(state, code, context)
    local row = {code=type(code) == "string" and code or "harvestFailure",
        context={}}
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
    if type(state.port.diagnose) == "function" then
        pcall(state.port.diagnose, row.code, row.context)
    end
end

local function bindingsCurrent()
    return classState.installed and classState.bridgeCount > 0
end

local function authoritative(state, object)
    local ok, result = pcall(state.port.isAuthoritative, object)
    return ok and result == true
end

local function currentSequence(state)
    local ok, result = pcall(state.port.getSequence)
    if not ok or not integer(result, 1, 2147483647) then return nil end
    return result
end

local function fruitName(index)
    return token(method(_G.g_fruitTypeManager,
        "getFruitTypeNameByIndex", index), 128)
end

local function fillName(index)
    return token(method(_G.g_fillTypeManager,
        "getFillTypeNameByIndex", index), 128)
end

local function upper(value)
    if token(value, 128) == nil then return nil end
    return string.upper(value)
end

local function cropContract(inputName, outputName)
    local input = upper(inputName)
    local output = upper(outputName)
    local contract = input ~= nil and CROP_CONTRACTS[input] or nil
    if contract == nil then return nil, "unsupportedCrop" end
    if output ~= contract.output then return nil, "cropFillMismatch" end
    return contract
end

local function cutterMatches(header, combine, area, inputFruitType, outputFillType)
    local spec = type(header) == "table" and header.spec_cutter or nil
    local parameters = type(spec) == "table" and spec.workAreaParameters or nil
    return type(parameters) == "table"
        and rawequal(parameters.combineVehicle, combine)
        and parameters.lastArea == area
        and parameters.lastLiters == 0
        and spec.useWindrow == false
        and spec.currentOutputFillType == outputFillType
        and parameters.lastFruitType == inputFruitType
end

local function matchingProducer(combine, area, inputFruitType, outputFillType)
    local combineSpec = type(combine) == "table" and combine.spec_combine or nil
    local attached = type(combineSpec) == "table"
        and combineSpec.attachedCutters or nil
    local seen = {}
    local candidate = nil
    local count = 0
    local function consider(header)
        if type(header) == "table" and not seen[header]
            and cutterMatches(header, combine, area,
                inputFruitType, outputFillType) then
            seen[header] = true
            count = count + 1
            candidate = header
        end
    end
    if type(attached) == "table" then
        for key, value in pairs(attached) do
            consider(type(value) == "table" and value
                or (type(key) == "table" and key or nil))
        end
    end
    -- Rice, vegetables, potatoes, sugarcane, cotton and several root machines
    -- carry Cutter and Combine on the same vehicle instead of attaching a
    -- separate header.
    consider(combine)
    -- Vine harvesters use VineCutter rather than WorkArea/Cutter. Its callback
    -- feeds this same Combine contract; callable identity is checked before
    -- these rows are accepted.
    local vine = type(combine) == "table" and combine.spec_vineCutter or nil
    if type(vine) == "table" and vine.inputFruitTypeIndex == inputFruitType
        and vine.outputFillTypeIndex == outputFillType and not seen[combine] then
        seen[combine] = true
        count = count + 1
        candidate = combine
    end
    return count == 1 and candidate or nil, count
end

local function contextFor(state, combine, arguments)
    if not authoritative(state, combine) then return nil, "notAuthoritative" end
    local area = arguments[1]
    local requestedLitres = arguments[2]
    local inputFruitType = arguments[3]
    local outputFillType = arguments[4]
    local farmId = arguments[6]
    if not finite(area) or area <= 0 or area > MAX_PHYSICAL
        or not finite(requestedLitres) or requestedLitres < 0
        or requestedLitres > MAX_PHYSICAL
        or not integer(inputFruitType, 0, 2147483647)
        or not integer(outputFillType, 0, 2147483647)
        or not integer(farmId, 0, 2147483647) then
        return nil, "invalidArguments"
    end
    local combineSpec = type(combine) == "table" and combine.spec_combine or nil
    if type(combineSpec) ~= "table"
        or not integer(combineSpec.fillUnitIndex, 1, 2147483647) then
        return nil, "ineligibleCombine"
    end
    local capacity = method(combine, "getFillUnitCapacity",
        combineSpec.fillUnitIndex)
    local finiteTank = finite(capacity) and capacity > 0
        and capacity <= MAX_PHYSICAL
    local directDischarge = capacity == math.huge
    if not finiteTank and not directDischarge then
        return nil, "invalidCapacity"
    end
    local inputName = fruitName(inputFruitType)
    local outputName = fillName(outputFillType)
    local contract, contractReason = cropContract(inputName, outputName)
    if contract == nil then return nil, contractReason end
    local header, headerCount = matchingProducer(
        combine, area, inputFruitType, outputFillType)
    if header == nil then return nil, "headerMatch:" .. tostring(headerCount) end
    local headerFarm = method(header, "getLastTouchedFarmlandFarmId")
    if contract.family == "vineTank" then
        local vineSpec = type(header) == "table"
            and header.spec_vineCutter or nil
        headerFarm = type(vineSpec) == "table"
            and vineSpec.lastTouchedFarmlandFarmId or nil
        if not integer(headerFarm, 0, 2147483647) then
            return nil, "vineFarmUnavailable"
        end
    end
    if headerFarm ~= nil and headerFarm ~= farmId then
        return nil, "headerFarmMismatch"
    end
    local combineId = stableId(combine)
    local headerId = stableId(header)
    local rootId = stableId(rootVehicle(combine))
    local updateSequence = currentSequence(state)
    if combineId == nil or headerId == nil or rootId == nil
        or updateSequence == nil then return nil, "identityUnavailable" end
    local ordinal = state.ordinals[rootId]
    if ordinal == nil or ordinal.sequence ~= updateSequence then
        ordinal = {sequence=updateSequence, count=0}
        state.ordinals[rootId] = ordinal
    end
    ordinal.count = ordinal.count + 1
    if ordinal.count > MAX_ENTRIES then return nil, "tooManyEntries" end
    local discriminator = "cutter-" .. tostring(ordinal.count)
    local landToken = "harvest-" .. tostring(updateSequence)
        .. "-" .. tostring(ordinal.count)
    local normalized = {
        header = header,
        areaPixels = area,
        combineId = combineId,
        headerId = headerId,
        rootVehicleId = rootId,
        serverSequence = updateSequence,
        callDiscriminator = discriminator,
        farmId = farmId,
        inputFruitType = inputFruitType,
        inputFruitName = inputName,
        outputFillType = outputFillType,
        outputFillName = outputName,
        chainFamily = contract.family,
        finiteTank = finiteTank,
        directDischarge = directDischarge,
        landUpdateToken = landToken,
        compatibilityProfile = PROFILE
    }
    local spec = {
        authority=true, eligible=true, chainFamily=contract.family,
        finiteTank=finiteTank, directDischarge=directDischarge,
        combineId=combineId, headerId=headerId, rootVehicleId=rootId,
        serverSequence=updateSequence, callDiscriminator=discriminator,
        farmId=farmId, inputFruitType=inputFruitType,
        inputFruitName=inputName, outputFillType=outputFillType,
        outputFillName=outputName, landUpdateToken=landToken,
        compatibilityProfile=PROFILE, reasons={}
    }
    local reach = {
        combineId=combineId, headerId=headerId, rootVehicleId=rootId,
        serverSequence=updateSequence, callDiscriminator=discriminator,
        farmId=farmId, inputFruitType=inputFruitType,
        outputFillType=outputFillType, landUpdateToken=landToken
    }
    return spec, reach, normalized
end

local function removePending(state, key)
    if state.pending[key] ~= nil then
        state.pending[key] = nil
        state.pendingCount = math.max(0, state.pendingCount - 1)
    end
end

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

local function evictPending(state)
    while state.pendingCount >= MAX_PENDING do
        prunePendingOrder(state)
        local key = state.pendingOrder[state.pendingHead]
        if key == nil then return false end
        state.pendingHead = state.pendingHead + 1
        if state.pending[key] ~= nil then
            removePending(state, key)
            diagnose(state, "harvestPendingEvicted", {})
            return true
        end
    end
    return true
end

local function stageFact(state, context, fact)
    if active ~= state or (fact ~= nil and (type(fact) ~= "table"
        or not finite(fact.harvestedLitres) or fact.harvestedLitres <= 0
        or fact.harvestedLitres > MAX_PHYSICAL)) then return nil end
    local key = pendingKey(context.rootVehicleId, context.serverSequence)
    local bucket = state.pending[key]
    if bucket == nil then
        prunePendingOrder(state)
        if not evictPending(state) then return nil end
        bucket = {rootVehicleId=context.rootVehicleId,
            serverSequence=context.serverSequence, entries={}, augmented=false}
        state.pending[key] = bucket
        state.pendingOrder[#state.pendingOrder + 1] = key
        state.pendingCount = state.pendingCount + 1
    end
    if #bucket.entries >= MAX_ENTRIES then return nil end
    context.fact = fact
    bucket.entries[#bucket.entries + 1] = context
    return true
end

function HarvestRuntimeAdapter.observeVehicleCall(self, pristine, ...)
    local state = active
    if state == nil or state.disabled then return pristine(self, ...) end
    local arguments = pack(...)
    local spec, reach, context = contextFor(state, self, arguments)
    if spec == nil then return pristine(self, ...) end
    local scope = state.observer:openScope(spec)
    local ticket = scope ~= nil and state.observer:beginReach(scope, reach)
        or nil
    local invocation = invoke(pristine, self, arguments)
    if invocation[1] ~= true then
        if ticket ~= nil then state.observer:failReach(ticket) end
        if scope ~= nil then
            state.observer:closeScope(scope, "observerFailure")
        end
        error(invocation[2], 0)
    end
    if ticket ~= nil then
        state.observer:completeReach(ticket, returnedValues(invocation))
    end
    if scope ~= nil then
        local fact, reason = state.observer:closeScope(scope)
        if fact ~= nil or reason == nil then
            if not stageFact(state, context, fact) then
                diagnose(state, "harvestFactDiscarded", {
                    rootVehicleId=context.rootVehicleId,
                    serverSequence=context.serverSequence
                })
            end
        elseif reason ~= "duplicateObservation" then
            diagnose(state, reason, {rootVehicleId=context.rootVehicleId})
        end
    end
    return replay(invocation)
end

function HarvestRuntimeAdapter.installClassWrapper(...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    if classState.installed then return true, false end
    local pristine = type(_G.Combine) == "table" and Combine.addCutterArea or nil
    if type(pristine) ~= "function" then
        classState.reason = "harvestClassUnavailable"
        return nil, classState.reason
    end
    classState.original = pristine
    classState.installed = true
    classState.reason = nil
    return true, true
end

function HarvestRuntimeAdapter.registerVehicleBridge(...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    if not classState.installed then
        return nil, classState.reason or "harvestClassUnavailable"
    end
    classState.bridgeCount = classState.bridgeCount + 1
    return true, classState.bridgeCount
end

function HarvestRuntimeAdapter.activate(port, ...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    if active ~= nil then
        if rawequal(active.port, port) then return true, false end
        return nil, "harvestAlreadyActive"
    end
    local required = {"isSinglePlayer", "isAuthoritative", "getSequence",
        "getAttributionSnapshots", "resolveAttribution", "areaToHa",
        "acceptObservedFact"}
    if type(port) ~= "table" or getmetatable(port) ~= nil then
        return nil, "invalidHarvestPort"
    end
    for _, name in ipairs(required) do
        if type(port[name]) ~= "function" then return nil, "invalidHarvestPort" end
    end
    local ok, supported = pcall(port.isSinglePlayer)
    if not ok or supported ~= true then return nil, "unsupportedRole" end
    if not bindingsCurrent() then
        return nil, classState.reason or "harvestBindingsUnavailable"
    end
    local observerClass = type(FieldProfitabilityLedger.Adapters) == "table"
        and FieldProfitabilityLedger.Adapters.HarvestObserver or nil
    if type(observerClass) ~= "table" or type(observerClass.new) ~= "function" then
        return nil, "harvestObserverUnavailable"
    end
    local observer, reason = observerClass.new({
        maxDepth=16, maxHarvestedLitres=MAX_PHYSICAL,
        diagnosticCapacity=64, replayCapacity=256,
        maxReasons=16, maxTextBytes=256
    })
    if observer == nil then return nil, reason end
    active = {port=port, observer=observer, pending={}, pendingOrder={},
        pendingHead=1, pendingCount=0, ordinals={}, diagnostics={}, omittedDiagnostics=0,
        disabled=false}
    return true, true
end

local function attributionIdentity(value)
    return table.concat({
        tostring(value.kind), tostring(value.landKey), tostring(value.farmId),
        tostring(value.farmlandId), tostring(value.fieldId),
        tostring(value.fieldKind), tostring(value.cycleAreaHa)
    }, "\31")
end

local function detachedSnapshots(state, header)
    local called, snapshots, reason = pcall(
        state.port.getAttributionSnapshots, header)
    if not called or type(snapshots) ~= "table" or #snapshots == 0 then
        return nil, type(reason) == "string" and reason
            or "harvestSnapshotUnavailable"
    end
    local identity = nil
    local firstAttribution = nil
    for index = 1, #snapshots do
        local resolved, attribution, attributionReason = pcall(
            state.port.resolveAttribution, snapshots[index])
        if not resolved or type(attribution) ~= "table"
            or (attribution.kind ~= "baseField"
                and attribution.kind ~= "parcel") then
            return nil, type(attributionReason) == "string"
                and attributionReason or "harvestAttributionRejected"
        end
        local current = attributionIdentity(attribution)
        if identity == nil then
            identity = current
            firstAttribution = attribution
        elseif identity ~= current then
            return nil, "harvestDistinctLand"
        end
    end
    return snapshots[1], firstAttribution
end

function HarvestRuntimeAdapter.augmentUpdate(root, update, ...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    local state = active
    if state == nil then return update end
    if type(update) ~= "table" or getmetatable(update) ~= nil
        or token(update.rootVehicleId, 64) == nil
        or not integer(update.serverSequence, 1, 2147483647) then
        return nil, "invalidHarvestUpdate"
    end
    local key = pendingKey(update.rootVehicleId, update.serverSequence)
    local bucket = state.pending[key]
    if bucket == nil or bucket.augmented then return update end
    local inputName, inputType, outputName, outputType = nil, nil, nil, nil
    local rows = {}
    for index, entry in ipairs(bucket.entries) do
        if not rawequal(rootVehicle(entry.header), root) then
            removePending(state, key)
            return nil, "harvestRootMismatch"
        end
        local snapshot, attributionOrReason = detachedSnapshots(
            state, entry.header)
        entry.header = nil
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
            return nil, "harvestFarmMismatch"
        end
        local converted, areaHa, areaReason = pcall(
            state.port.areaToHa, entry.areaPixels)
        if not converted or not finite(areaHa) or areaHa <= 0 then
            removePending(state, key)
            return nil, type(areaReason) == "string" and areaReason
                or "harvestAreaRejected"
        end
        if inputName == nil then
            inputName, inputType = entry.inputFruitName, entry.inputFruitType
            outputName, outputType = entry.outputFillName, entry.outputFillType
        elseif inputName ~= entry.inputFruitName
            or inputType ~= entry.inputFruitType
            or outputName ~= entry.outputFillName
            or outputType ~= entry.outputFillType then
            removePending(state, key)
            return nil, "harvestCropCollision"
        end
        rows[index] = {
            attributionSnapshot=snapshot,
            changedAreaHa=areaHa,
            observationDiscriminator=entry.landUpdateToken,
            operationType="ordinaryArableHarvest",
            workAreaType="cutter"
        }
    end
    if #update.rows + #rows > 128 then
        removePending(state, key)
        return nil, "tooManyRows"
    end
    for _, row in ipairs(rows) do update.rows[#update.rows + 1] = row end
    update.fruitType = inputName
    update.fruitTypeId = inputType
    update.fillType = outputName
    update.fillTypeId = outputType
    bucket.augmented = true
    return update
end

function HarvestRuntimeAdapter.onAcceptedUpdate(update, ...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    local state = active
    if state == nil then return true, 0 end
    if type(update) ~= "table" or token(update.rootVehicleId, 64) == nil
        or not integer(update.serverSequence, 1, 2147483647)
        or type(update.operations) ~= "table" then
        return nil, "invalidAcceptedUpdate"
    end
    local key = pendingKey(update.rootVehicleId, update.serverSequence)
    local bucket = state.pending[key]
    if bucket == nil then return true, 0 end
    removePending(state, key)
    local operationDiscriminator = nil
    for _, operation in ipairs(update.operations) do
        if type(operation) == "table"
            and operation.operationType == "ordinaryArableHarvest" then
            operationDiscriminator = operation.observationDiscriminator
        end
    end
    if token(operationDiscriminator, 64) == nil then
        diagnose(state, "harvestAcceptedLandMissing", {
            rootVehicleId=bucket.rootVehicleId,
            serverSequence=bucket.serverSequence
        })
        return true, 0
    end
    local amount = 0
    local first = nil
    local combines, headers = {}, {}
    local combineCount, headerCount = 0, 0
    for _, entry in ipairs(bucket.entries) do
        if entry.fact ~= nil then
            first = first or entry
            amount = amount + entry.fact.harvestedLitres
            if not finite(amount) or amount > MAX_PHYSICAL then
                return nil, "harvestAmountOutOfBounds"
            end
        end
        if not combines[entry.combineId] then
            combines[entry.combineId] = true
            combineCount = combineCount + 1
        end
        if not headers[entry.headerId] then
            headers[entry.headerId] = true
            headerCount = headerCount + 1
        end
    end
    if first == nil then return true, 0 end
    local called, record, reason = pcall(state.port.acceptObservedFact, {
        rootVehicleId=bucket.rootVehicleId,
        serverSequence=bucket.serverSequence,
        observationDiscriminator="h01",
        operationObservationDiscriminator=operationDiscriminator,
        recordType="harvest", category="harvest",
        amount=amount, unit="litres",
        qualityClass="Complete", reasons={},
        metadata={
            compatibilityProfile=PROFILE,
            chainFamily=first.chainFamily,
            finiteTank=first.finiteTank,
            directDischarge=first.directDischarge,
            combineCount=combineCount,
            headerCount=headerCount,
            inputFruitName=first.inputFruitName,
            outputFillName=first.outputFillName,
            outputFillTypeId=first.outputFillType
        }
    })
    if not called or type(record) ~= "table" then
        diagnose(state, type(reason) == "string" and reason
            or "harvestFactRejected", {
            rootVehicleId=bucket.rootVehicleId,
            serverSequence=bucket.serverSequence
        })
        return true, 0
    end
    return true, 1
end

function HarvestRuntimeAdapter.discardUpdate(
    rootVehicleId, serverSequence, ...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    local state = active
    if state == nil then return true, false end
    local root = token(rootVehicleId, 64)
    if root == nil or not integer(serverSequence, 1, 2147483647) then
        return nil, "invalidHarvestUpdate"
    end
    local key = pendingKey(root, serverSequence)
    if state.pending[key] == nil then return true, false end
    removePending(state, key)
    return true, true
end

function HarvestRuntimeAdapter.abortLifecycle(lifecycle, ...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    local state = active
    if state == nil then return true, false end
    local ok = state.observer:abort(lifecycle)
    if ok == nil then return nil, "harvestLifecycleRejected" end
    state.pending = {}
    state.pendingOrder = {}
    state.pendingHead = 1
    state.pendingCount = 0
    state.ordinals = {}
    if lifecycle == "unload" then active = nil end
    return true, true
end

function HarvestRuntimeAdapter.getStatus(...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    local state = active
    local rows = {}
    if state ~= nil then
        for index, row in ipairs(state.diagnostics) do
            local context = {}
            for key, value in pairs(row.context) do context[key] = value end
            rows[index] = {code=row.code, context=context}
        end
    end
    return {active=state ~= nil, bindingsInstalled=bindingsCurrent(),
        classContractInstalled=classState.installed,
        vehicleBridgeCount=classState.bridgeCount,
        disabled=state ~= nil and state.disabled or false,
        pendingUpdates=state ~= nil and state.pendingCount or 0,
        diagnostics=rows,
        omittedDiagnostics=state ~= nil and state.omittedDiagnostics or 0,
        reason=classState.reason}
end

FieldProfitabilityLedger.Runtime.HarvestRuntimeAdapter = HarvestRuntimeAdapter
return HarvestRuntimeAdapter
