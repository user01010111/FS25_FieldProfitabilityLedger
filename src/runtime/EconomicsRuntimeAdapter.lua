-- Converts accepted physical observations into frozen, explicitly labelled
-- replacement values and estimated harvest value. It never intercepts money
-- and never describes a derived value as realized cash profit.

FieldProfitabilityLedger = FieldProfitabilityLedger or {}
FieldProfitabilityLedger.Runtime = FieldProfitabilityLedger.Runtime or {}

local EconomicsRuntimeAdapter = {}
local active = nil

local INPUT_CATEGORIES = {
    seed=true, fertilizer=true, lime=true, herbicide=true,
    manure=true, slurry=true, digestate=true
}

local function finite(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function dependencies()
    local root = FieldProfitabilityLedger
    local core = type(root) == "table" and rawget(root, "Core") or nil
    local constants = type(core) == "table" and rawget(core, "Constants") or nil
    local accounting = type(core) == "table" and rawget(core, "Accounting") or nil
    local identifiers = type(core) == "table" and rawget(core, "Identifiers") or nil
    if type(constants) ~= "table" or type(accounting) ~= "table"
        or type(accounting.replacementValue) ~= "function"
        or type(accounting.estimatedHarvestValue) ~= "function"
        or type(identifiers) ~= "table"
        or type(identifiers.parseObservationId) ~= "function" then
        return nil, "economicsDependencyUnavailable"
    end
    return {constants=constants, accounting=accounting, identifiers=identifiers}
end

local function copyReasons(value)
    local result = {}
    for index, reason in ipairs(value or {}) do result[index] = reason end
    return result
end

local function classification(record, constants)
    local metadata = type(record) == "table"
        and type(record.metadata) == "table" and record.metadata or {}
    if metadata.unallocated == true then return nil end
    if record.recordType == constants.RECORD_TYPE.Input
        and INPUT_CATEGORIES[record.category] then
        return constants.ACCOUNTING_CLASS.Valued,
            constants.CATEGORY.inputReplacementValue,
            constants.DIRECTION.Expense, "replacement", "valuation"
    elseif record.recordType == constants.RECORD_TYPE.Machinery
        and record.category == constants.CATEGORY.fuel then
        if metadata.authoritativeDirectCost == true then return nil end
        return constants.ACCOUNTING_CLASS.Valued,
            constants.CATEGORY.fuelReplacementValue,
            constants.DIRECTION.Expense, "replacement", "valuation"
    elseif record.recordType == constants.RECORD_TYPE.Machinery
        and record.category == constants.CATEGORY.def then
        return constants.ACCOUNTING_CLASS.Valued,
            constants.CATEGORY.defReplacementValue,
            constants.DIRECTION.Expense, "replacement", "valuation"
    elseif record.recordType == constants.RECORD_TYPE.Harvest
        and record.category == constants.CATEGORY.harvest then
        return constants.ACCOUNTING_CLASS.Estimated,
            constants.CATEGORY.estimatedHarvestValue,
            constants.DIRECTION.IncomeValue, "harvest", "valuation"
    elseif record.recordType == constants.RECORD_TYPE.Labour
        and record.category == constants.CATEGORY.aiLabourTime then
        if metadata.authoritativeAIJob == true then return nil end
        return constants.ACCOUNTING_CLASS.Allocated,
            constants.CATEGORY.aiLabourAllocation,
            constants.DIRECTION.Expense, "aiLabour", "allocation"
    elseif record.recordType == constants.RECORD_TYPE.Machinery
        and record.category == constants.CATEGORY.wearDelta then
        return constants.ACCOUNTING_CLASS.Allocated,
            constants.CATEGORY.repairLiability,
            constants.DIRECTION.Expense, "repair", "allocation"
    elseif record.recordType == constants.RECORD_TYPE.Machinery
        and record.category == constants.CATEGORY.workingTime
        and type(record.metadata) == "table"
        and type(record.metadata.leaseCandidates) == "table"
        and #record.metadata.leaseCandidates > 0 then
        return constants.ACCOUNTING_CLASS.Allocated,
            constants.CATEGORY.leaseAllocation,
            constants.DIRECTION.Expense, "lease", "allocation"
    end
    return nil
end

local function fillTypeId(state, record)
    local metadata = type(record.metadata) == "table" and record.metadata or {}
    local value = rawget(metadata, "fillTypeId")
        or rawget(metadata, "outputFillTypeId")
    if finite(value) and value >= 0 and value == math.floor(value) then
        return value
    end
    local name = rawget(metadata, "fillName")
        or rawget(metadata, "outputFillName")
    if type(name) == "string" and type(state.port.resolveFillType) == "function" then
        local ok, resolved = pcall(state.port.resolveFillType, name)
        if ok and finite(resolved) and resolved >= 0
            and resolved == math.floor(resolved) then return resolved end
    end
    return nil
end

local function appendUnsupported(state, record, accountingClass, category,
    recordType, parsed, reason)
    local observationId, observationReason = state.ledger:createObservationId(
        "economics", parsed.sequence, "value-" .. record.id)
    if observationId == nil then return nil, observationReason end
    return state.ledger:acceptRecord({
        cycleId=record.cycleId, sessionId=record.sessionId,
        recordType=recordType, category=category,
        accountingClass=accountingClass, qualityClass="Unsupported",
        missionTime=record.missionTime, observationId=observationId,
        segmentKey="value-" .. category .. "-" .. record.id,
        basisId=record.id, reasons={reason or "priceUnavailable"},
        metadata={priceSource="fs25CurrentEconomy",
            sourceRecordId=record.id}, references={record.id}
    })
end

local function frozenBasisKey(category, recordId)
    return category .. "\31" .. recordId
end

local function cacheUnsupportedBasis(
        state, key, priceKind, typeId, reason)
    local basis = {
        priceKind=priceKind, typeId=typeId == nil and false or typeId,
        supported=false, reason=reason
    }
    state.frozenBasisByKey[key] = basis
    return basis
end

function EconomicsRuntimeAdapter.activate(ledger, port, ...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    if active ~= nil then
        if rawequal(active.ledger, ledger) and rawequal(active.port, port) then
            return true, false
        end
        return nil, "economicsAlreadyActive"
    end
    if type(ledger) ~= "table" or type(ledger.acceptRecord) ~= "function"
        or type(ledger.createObservationId) ~= "function"
        or type(port) ~= "table" or getmetatable(port) ~= nil
        or type(port.getReplacementPrice) ~= "function"
        or type(port.getHarvestPrice) ~= "function"
        or type(port.getAiLabourPricePerMs) ~= "function" then
        return nil, "invalidEconomicsPort"
    end
    local deps, reason = dependencies()
    if deps == nil then return nil, reason end
    active = {ledger=ledger, port=port, deps=deps, frozenBasisByKey={}}
    return true, true
end

function EconomicsRuntimeAdapter.onObservedRecord(record, ...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    local state = active
    if state == nil then return true, false end
    if type(record) ~= "table" or getmetatable(record) ~= nil
        or type(record.id) ~= "string" or type(record.observationId) ~= "string"
        or not finite(record.amount) or record.amount < 0 then
        return nil, "invalidObservedRecord"
    end
    local accountingClass, category, direction, priceKind, derivedRecordType =
        classification(record, state.deps.constants)
    if accountingClass == nil then return true, false end
    local parsed, parseReason = state.deps.identifiers.parseObservationId(
        record.observationId)
    if parsed == nil then return nil, parseReason end
    local typeId, price, amount, amountReason = nil, nil, nil, nil
    local derivationMetadata = {sourceRecordId=record.id}
    if priceKind == "replacement" or priceKind == "harvest" then
        local basisKey = frozenBasisKey(category, record.id)
        local basis = state.frozenBasisByKey[basisKey]
        typeId = fillTypeId(state, record)
        local normalizedTypeId = typeId == nil and false or typeId
        if basis ~= nil and (basis.priceKind ~= priceKind
            or basis.typeId ~= normalizedTypeId) then
            return nil, "economicsBasisCollision"
        end
        if basis ~= nil and basis.supported ~= true then
            return appendUnsupported(state, record, accountingClass, category,
                derivedRecordType, parsed, basis.reason)
        end
        if typeId == nil then
            cacheUnsupportedBasis(state, basisKey, priceKind, nil,
                "fillTypePriceUnavailable")
            return appendUnsupported(state, record, accountingClass, category,
                derivedRecordType, parsed, "fillTypePriceUnavailable")
        end
        if basis == nil then
            local priceCall = priceKind == "harvest"
                and state.port.getHarvestPrice
                or state.port.getReplacementPrice
            local called
            called, price = pcall(priceCall, typeId)
            if not called or not finite(price) or price < 0 then
                cacheUnsupportedBasis(state, basisKey, priceKind, typeId,
                    "priceUnavailable")
                return appendUnsupported(state, record, accountingClass,
                    category, derivedRecordType, parsed, "priceUnavailable")
            end
            basis = {priceKind=priceKind, typeId=typeId,
                supported=true, price=price}
            state.frozenBasisByKey[basisKey] = basis
        else
            price = basis.price
        end
        if priceKind == "harvest" then
            amount, amountReason = state.deps.accounting.estimatedHarvestValue(
                record.amount, price)
        else
            amount, amountReason = state.deps.accounting.replacementValue(
                record.amount, price)
        end
        derivationMetadata.fillTypeId = typeId
        derivationMetadata.frozenPricePerLiter = price
        derivationMetadata.priceSource = "fs25CurrentEconomy"
    elseif priceKind == "aiLabour" then
        local basisKey = frozenBasisKey(category, record.id)
        local basis = state.frozenBasisByKey[basisKey]
        if basis ~= nil and basis.priceKind ~= priceKind then
            return nil, "economicsBasisCollision"
        end
        if basis ~= nil and basis.supported ~= true then
            return appendUnsupported(state, record, accountingClass, category,
                derivedRecordType, parsed, basis.reason)
        end
        local perMs = nil
        if basis == nil then
            local called
            called, perMs = pcall(state.port.getAiLabourPricePerMs)
            if not called or not finite(perMs) or perMs < 0 then
                cacheUnsupportedBasis(state, basisKey, priceKind, nil,
                    "aiLabourRateUnavailable")
                return appendUnsupported(state, record, accountingClass,
                    category, derivedRecordType, parsed,
                    "aiLabourRateUnavailable")
            end
            basis = {priceKind=priceKind, typeId=false,
                supported=true, price=perMs}
            state.frozenBasisByKey[basisKey] = basis
        else
            perMs = basis.price
        end
        local hourlyRate = perMs * 3600000
        amount, amountReason = state.deps.accounting.playerLabourAllocation(
            hourlyRate, record.amount)
        derivationMetadata.frozenPricePerMs = perMs
        derivationMetadata.frozenHourlyRate = hourlyRate
        derivationMetadata.rateSource = "fs25AIFieldWork"
    elseif priceKind == "repair" then
        local metadata = record.metadata or {}
        amount = rawget(metadata, "repairLiabilityAmount")
        if rawget(metadata, "repairLiabilitySupported") ~= true
            or not finite(amount) or amount < 0 then
            return appendUnsupported(state, record, accountingClass, category,
                derivedRecordType, parsed, "repairCurveUnavailable")
        end
        derivationMetadata.damageBefore = metadata.damageBefore
        derivationMetadata.damageAfter = metadata.damageAfter
        derivationMetadata.curveSource = "Wearable.calculateRepairPrice"
    elseif priceKind == "lease" then
        amount = 0
        local candidates = record.metadata.leaseCandidates
        local normalized = {}
        for index, candidate in ipairs(candidates) do
            if type(candidate) ~= "table" then
                return nil, "invalidLeaseCandidate"
            end
            local milliseconds = candidate.activeOperatingMs
            local priceBasis = candidate.priceBasis
            local factor = candidate.runningLeasingFactor
            if not finite(milliseconds) or milliseconds < 0
                or not finite(priceBasis) or priceBasis < 0
                or not finite(factor) or factor < 0 then
                return nil, "invalidLeaseCandidate"
            end
            local allocated, reason = state.deps.accounting.leaseAllocation(
                priceBasis, factor, milliseconds / 3600000)
            if allocated == nil then return nil, reason end
            amount = amount + allocated
            if not finite(amount) or amount > 1000000000000 then
                return nil, "leaseAllocationOutOfRange"
            end
            normalized[index] = {
                objectId=candidate.objectId, role=candidate.role,
                activeOperatingMs=milliseconds, priceBasis=priceBasis,
                runningLeasingFactor=factor
            }
        end
        derivationMetadata.candidates = normalized
        derivationMetadata.formula = "price*runningFactor*activeHours"
    end
    if amount == nil then return nil, amountReason end
    local observationId, observationReason = state.ledger:createObservationId(
        "economics", parsed.sequence, "value-" .. record.id)
    if observationId == nil then return nil, observationReason end
    local reasons = copyReasons(record.reasons)
    local quality = record.qualityClass
    local valued, createdOrReason = state.ledger:acceptRecord({
        cycleId=record.cycleId, sessionId=record.sessionId,
        recordType=derivedRecordType, category=category,
        accountingClass=accountingClass, qualityClass=quality,
        amount=amount, unit="money", direction=direction,
        missionTime=record.missionTime, observationId=observationId,
        segmentKey="value-" .. category .. "-" .. record.id,
        basisId=record.id, reasons=reasons,
        metadata=derivationMetadata,
        references={record.id}
    })
    if valued == nil then return nil, createdOrReason end
    return valued, createdOrReason
end

function EconomicsRuntimeAdapter.abortLifecycle(lifecycle, ...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    if type(lifecycle) ~= "string" then return nil, "invalidLifecycle" end
    if active == nil then return true, false end
    if lifecycle == "unload" then active = nil end
    return true, true
end

function EconomicsRuntimeAdapter.getStatus(...)
    if select("#", ...) ~= 0 then return nil, "unexpectedArgument" end
    return {active=active ~= nil}
end

FieldProfitabilityLedger.Runtime.EconomicsRuntimeAdapter =
    EconomicsRuntimeAdapter
return EconomicsRuntimeAdapter
