-- FieldProfitabilityLedger pure accounting formulas.
-- This module deliberately has no Farming Simulator runtime dependencies.

FieldProfitabilityLedger = FieldProfitabilityLedger or {}
FieldProfitabilityLedger.Core = FieldProfitabilityLedger.Core or {}

local Accounting = {}

local VALIDATION_SUFFIX = {
    invalidMinimum = "InvalidMinimum",
    invalidMaximum = "InvalidMaximum",
    invalidRange = "InvalidRange",
    expectedNumber = "ExpectedNumber",
    notFinite = "NotFinite",
    belowMinimum = "BelowMinimum",
    aboveMaximum = "AboveMaximum"
}

local function validation()
    local core = rawget(FieldProfitabilityLedger, "Core")
    if type(core) ~= "table" then
        return nil
    end

    local candidate = rawget(core, "Validation")
    if type(candidate) ~= "table" then
        return nil
    end

    return candidate
end

local function identifiers()
    local core = rawget(FieldProfitabilityLedger, "Core")
    if type(core) ~= "table" then
        return nil
    end

    local candidate = rawget(core, "Identifiers")
    if type(candidate) ~= "table" or type(rawget(candidate, "compare")) ~= "function" then
        return nil
    end

    return candidate
end

local function finiteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function unsignedByteLess(left, right)
    local sharedLength = math.min(#left, #right)
    for i = 1, sharedLength do
        local leftByte = string.byte(left, i)
        local rightByte = string.byte(right, i)
        if leftByte ~= rightByte then
            return leftByte < rightByte
        end
    end
    return #left < #right
end

local function policyInteger(source, key, minimum)
    local value = rawget(source, key)
    if not finiteNumber(value) or value ~= math.floor(value) or value < minimum then
        return nil
    end
    return value
end

local function policyToken(source, key, maximumBytes)
    local value = rawget(source, key)
    if type(value) ~= "string" or #value == 0 or #value > maximumBytes then
        return nil
    end
    for i = 1, #value do
        local byte = string.byte(value, i)
        if byte < 33 or byte > 126 then
            return nil
        end
    end
    return value
end

local function resolvePolicy()
    local core = rawget(FieldProfitabilityLedger, "Core")
    if type(core) ~= "table" then
        return nil, "constantsUnavailable"
    end

    local constants = rawget(core, "Constants")
    if type(constants) ~= "table" or getmetatable(constants) ~= nil then
        return nil, "constantsUnavailable"
    end

    local limits = rawget(constants, "LIMITS")
    local quality = rawget(constants, "QUALITY_CLASS")
    local confidence = rawget(constants, "CONFIDENCE")
    if type(limits) ~= "table" or getmetatable(limits) ~= nil
        or type(quality) ~= "table" or getmetatable(quality) ~= nil
        or type(confidence) ~= "table" or getmetatable(confidence) ~= nil then
        return nil, "constantsUnavailable"
    end

    local idBytes = policyInteger(limits, "idBytes", 1)
    local tokenBytes = policyInteger(limits, "tokenBytes", 1)
    local maxPhysical = policyInteger(limits, "maxPhysical", 0)
    local maxAreaHa = policyInteger(limits, "maxAreaHa", 0)
    local maxMoney = policyInteger(limits, "maxMoney", 0)
    local maxUnitPrice = policyInteger(limits, "maxUnitPrice", 0)
    local maxDurationMs = policyInteger(limits, "maxDurationMs", 0)
    local maxReasons = policyInteger(limits, "maxReasons", 1)
    local maxComponents = policyInteger(limits, "maxComponents", 1)
    if idBytes == nil or tokenBytes == nil or maxPhysical == nil
        or maxAreaHa == nil or maxMoney == nil or maxUnitPrice == nil
        or maxDurationMs == nil or maxReasons == nil or maxComponents == nil then
        return nil, "constantsUnavailable"
    end

    local qualityComplete = policyToken(quality, "Complete", tokenBytes)
    local qualityPartial = policyToken(quality, "Partial", tokenBytes)
    local qualityUnsupported = policyToken(quality, "Unsupported", tokenBytes)
    local confidenceHigh = policyToken(confidence, "High", tokenBytes)
    local confidenceMedium = policyToken(confidence, "Medium", tokenBytes)
    local confidenceLow = policyToken(confidence, "Low", tokenBytes)
    local confidenceNotApplicable = policyToken(confidence, "NotApplicable", tokenBytes)
    if qualityComplete == nil or qualityPartial == nil or qualityUnsupported == nil
        or confidenceHigh == nil or confidenceMedium == nil
        or confidenceLow == nil or confidenceNotApplicable == nil then
        return nil, "constantsUnavailable"
    end
    if qualityComplete == qualityPartial or qualityComplete == qualityUnsupported
        or qualityPartial == qualityUnsupported
        or confidenceHigh == confidenceMedium or confidenceHigh == confidenceLow
        or confidenceHigh == confidenceNotApplicable
        or confidenceMedium == confidenceLow
        or confidenceMedium == confidenceNotApplicable
        or confidenceLow == confidenceNotApplicable then
        return nil, "constantsUnavailable"
    end

    return {
        idBytes = idBytes,
        reasonBytes = tokenBytes,
        maxPhysical = maxPhysical,
        maxAreaHa = maxAreaHa,
        maxMoney = maxMoney,
        maxUnitPrice = maxUnitPrice,
        maxDurationMs = maxDurationMs,
        maxActiveHours = maxDurationMs / 3600000,
        maxReasons = maxReasons,
        maxComponents = maxComponents,
        qualityComplete = qualityComplete,
        qualityPartial = qualityPartial,
        qualityUnsupported = qualityUnsupported,
        confidenceHigh = confidenceHigh,
        confidenceMedium = confidenceMedium,
        confidenceLow = confidenceLow,
        confidenceNotApplicable = confidenceNotApplicable
    }
end

local function validationReason(prefix, reason)
    return prefix .. (VALIDATION_SUFFIX[reason] or "Invalid")
end

local function checkedNumber(value, minimum, maximum, prefix)
    local validator = validation()
    if validator == nil or type(rawget(validator, "number")) ~= "function" then
        return nil, "validationUnavailable"
    end

    local accepted, reason = validator.number(value, minimum, maximum)
    if accepted == nil then
        return nil, validationReason(prefix, reason)
    end

    return accepted
end

local function checkedArray(value, maximumItems, reasonCode)
    local validator = validation()
    if validator == nil or type(rawget(validator, "array")) ~= "function" then
        return nil, "validationUnavailable"
    end

    local accepted = validator.array(value, maximumItems)
    if accepted == nil then
        return nil, reasonCode
    end

    return accepted
end

local function checkedAscii(value, maximumBytes, reasonCode)
    local validator = validation()
    if validator == nil or type(rawget(validator, "asciiToken")) ~= "function" then
        return nil, "validationUnavailable"
    end

    local accepted = validator.asciiToken(value, maximumBytes)
    if accepted == nil then
        return nil, reasonCode
    end

    return accepted
end

local function isFinite(value)
    local validator = validation()
    if validator == nil or type(rawget(validator, "isFinite")) ~= "function" then
        return false
    end

    return validator.isFinite(value)
end

local function checkedMoneyResult(value, reasonCode, policy)
    if not isFinite(value) or value < -policy.maxMoney or value > policy.maxMoney then
        return nil, reasonCode
    end

    return value
end

local function checkedNonNegativeMoneyResult(value, reasonCode, policy)
    if not isFinite(value) or value < 0 or value > policy.maxMoney then
        return nil, reasonCode
    end

    return value
end

local function addMoney(total, amount, reasonCode, policy)
    return checkedNonNegativeMoneyResult(total + amount, reasonCode, policy)
end

local function validateKnownKeys(value, allowed, reasonCode)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        return nil, reasonCode
    end

    for key in next, value do
        if allowed[key] ~= true then
            return nil, reasonCode
        end
    end

    return value
end

local function valueFromQuantity(quantity, pricePerUnit, quantityPrefix, pricePrefix, policy)
    local acceptedQuantity, reason = checkedNumber(
        quantity,
        0,
        policy.maxPhysical,
        quantityPrefix
    )
    if acceptedQuantity == nil then
        return nil, reason
    end

    local acceptedPrice
    acceptedPrice, reason = checkedNumber(
        pricePerUnit,
        0,
        policy.maxUnitPrice,
        pricePrefix
    )
    if acceptedPrice == nil then
        return nil, reason
    end

    return checkedNonNegativeMoneyResult(
        acceptedQuantity * acceptedPrice,
        "valuedAmountOutOfRange",
        policy
    )
end

function Accounting.replacementValue(quantity, pricePerUnit)
    local policy, reason = resolvePolicy()
    if policy == nil then
        return nil, reason
    end
    return valueFromQuantity(
        quantity,
        pricePerUnit,
        "quantity",
        "pricePerUnit",
        policy
    )
end

function Accounting.estimatedHarvestValue(quantity, frozenPricePerUnit)
    local policy, reason = resolvePolicy()
    if policy == nil then
        return nil, reason
    end
    return valueFromQuantity(
        quantity,
        frozenPricePerUnit,
        "harvestQuantity",
        "frozenPricePerUnit",
        policy
    )
end

local GROSS_MARGIN_PART_KEYS = {
    estimatedHarvestValue = true,
    directObservedCosts = true,
    replacementValuedInputs = true,
    replacementFuelValue = true,
    replacementDefValue = true,
    allocatedCosts = true,
    directReplacementOverlap = true
}

local GROSS_MARGIN_INCLUSION_KEYS = {
    direct = true,
    inputs = true,
    fuel = true,
    def = true,
    allocated = true
}

local function checkedInclusionBoolean(inclusion, key)
    local value = rawget(inclusion, key)
    if type(value) ~= "boolean" then
        return nil, "invalidInclusion"
    end

    return value
end

local function selectedMoney(parts, key, included, policy)
    local value = rawget(parts, key)
    if value == nil then
        if included then
            return nil, key .. "Unavailable"
        end
        return 0
    end

    local accepted, reason = checkedNumber(value, 0, policy.maxMoney, key)
    if accepted == nil then
        return nil, reason
    end

    if included then
        return accepted
    end

    return 0
end

local function preflightAllocatedKeys(
    value,
    invalidMapReason,
    tooManyReason,
    policy
)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        return nil, invalidMapReason
    end

    -- Count is a separate bounded pass so size policy always precedes entry
    -- semantics, regardless of hash traversal order.
    local count = 0
    for _ in next, value do
        count = count + 1
        if count > policy.maxComponents then
            return nil, tooManyReason
        end
    end

    local validator = validation()
    if validator == nil or type(rawget(validator, "asciiToken")) ~= "function" then
        return nil, "validationUnavailable"
    end

    -- Classify every key before looking at any value. Invalid keys are never
    -- compared, so overlong common prefixes cannot reach the sort comparator.
    local keys = {}
    local invalidKey = false
    for key in next, value do
        local acceptedKey = validator.asciiToken(key, policy.idBytes)
        if acceptedKey == nil then
            invalidKey = true
        else
            keys[#keys + 1] = acceptedKey
        end
    end
    if invalidKey then
        return nil, "invalidAllocatedCostId"
    end

    table.sort(keys, unsignedByteLess)
    return keys
end

local function validateAllocatedMap(value, allowNil, policy)
    if value == nil and allowNil then
        return {}, {}
    end

    local keys, reason = preflightAllocatedKeys(
        value,
        "invalidAllocatedCosts",
        "tooManyAllocatedCosts",
        policy
    )
    if keys == nil then
        return nil, reason
    end

    for i = 1, #keys do
        local key = keys[i]
        local acceptedAmount
        acceptedAmount, reason = checkedNumber(
            rawget(value, key),
            0,
            policy.maxMoney,
            "allocatedCost"
        )
        if acceptedAmount == nil then
            return nil, reason
        end
    end

    return value, keys
end

local function validateAllocatedInclusion(value, policy)
    local keys, reason = preflightAllocatedKeys(
        value,
        "invalidAllocatedInclusion",
        "tooManyAllocatedInclusions",
        policy
    )
    if keys == nil then
        return nil, reason
    end

    for i = 1, #keys do
        local included = rawget(value, keys[i])
        if type(included) ~= "boolean" then
            return nil, "invalidAllocatedInclusion"
        end
    end

    return value, keys
end

function Accounting.grossMargin(parts, inclusion)
    local policy, reason = resolvePolicy()
    if policy == nil then
        return nil, reason
    end

    local acceptedParts
    acceptedParts, reason = validateKnownKeys(
        parts,
        GROSS_MARGIN_PART_KEYS,
        "invalidGrossMarginParts"
    )
    if acceptedParts == nil then
        return nil, reason
    end

    local acceptedInclusion
    acceptedInclusion, reason = validateKnownKeys(
        inclusion,
        GROSS_MARGIN_INCLUSION_KEYS,
        "invalidGrossMarginInclusion"
    )
    if acceptedInclusion == nil then
        return nil, reason
    end

    local includeDirect
    includeDirect, reason = checkedInclusionBoolean(acceptedInclusion, "direct")
    if includeDirect == nil then
        return nil, reason
    end
    local includeInputs
    includeInputs, reason = checkedInclusionBoolean(acceptedInclusion, "inputs")
    if includeInputs == nil then
        return nil, reason
    end
    local includeFuel
    includeFuel, reason = checkedInclusionBoolean(acceptedInclusion, "fuel")
    if includeFuel == nil then
        return nil, reason
    end
    local includeDef
    includeDef, reason = checkedInclusionBoolean(acceptedInclusion, "def")
    if includeDef == nil then
        return nil, reason
    end

    local overlap = rawget(acceptedParts, "directReplacementOverlap")
    if type(overlap) ~= "boolean" then
        return nil, "invalidDirectReplacementOverlap"
    end
    if overlap == true and includeDirect and (includeInputs or includeFuel or includeDef) then
        return nil, "directReplacementOverlap"
    end

    local estimatedValue
    estimatedValue, reason = checkedNumber(
        rawget(acceptedParts, "estimatedHarvestValue"),
        0,
        policy.maxMoney,
        "estimatedHarvestValue"
    )
    if estimatedValue == nil then
        return nil, reason
    end

    local selectedDirect
    selectedDirect, reason = selectedMoney(
        acceptedParts,
        "directObservedCosts",
        includeDirect,
        policy
    )
    if selectedDirect == nil then
        return nil, reason
    end
    local selectedInputs
    selectedInputs, reason = selectedMoney(
        acceptedParts,
        "replacementValuedInputs",
        includeInputs,
        policy
    )
    if selectedInputs == nil then
        return nil, reason
    end
    local selectedFuel
    selectedFuel, reason = selectedMoney(
        acceptedParts,
        "replacementFuelValue",
        includeFuel,
        policy
    )
    if selectedFuel == nil then
        return nil, reason
    end
    local selectedDef
    selectedDef, reason = selectedMoney(
        acceptedParts,
        "replacementDefValue",
        includeDef,
        policy
    )
    if selectedDef == nil then
        return nil, reason
    end

    local allocatedCosts, allocatedCostKeys
    allocatedCosts, allocatedCostKeys = validateAllocatedMap(
        rawget(acceptedParts, "allocatedCosts"),
        true,
        policy
    )
    if allocatedCosts == nil then
        return nil, allocatedCostKeys
    end

    local allocatedInclusion, allocatedInclusionKeys
    allocatedInclusion, allocatedInclusionKeys = validateAllocatedInclusion(
        rawget(acceptedInclusion, "allocated"),
        policy
    )
    if allocatedInclusion == nil then
        return nil, allocatedInclusionKeys
    end

    for i = 1, #allocatedInclusionKeys do
        local key = allocatedInclusionKeys[i]
        if rawget(allocatedInclusion, key) and rawget(allocatedCosts, key) == nil then
            return nil, "allocatedCostUnavailable"
        end
    end

    local selectedAllocated = {}
    local effectiveAllocatedInclusion = {}
    local allocatedTotal = 0
    for i = 1, #allocatedCostKeys do
        local key = allocatedCostKeys[i]
        if rawget(allocatedInclusion, key) == true then
            local amount = rawget(allocatedCosts, key)
            allocatedTotal, reason = addMoney(
                allocatedTotal,
                amount,
                "allocatedCostTotalOutOfRange",
                policy
            )
            if allocatedTotal == nil then
                return nil, reason
            end
            selectedAllocated[key] = amount
        end
        effectiveAllocatedInclusion[key] = rawget(allocatedInclusion, key) == true
    end
    for i = 1, #allocatedInclusionKeys do
        local key = allocatedInclusionKeys[i]
        if effectiveAllocatedInclusion[key] == nil then
            effectiveAllocatedInclusion[key] = rawget(allocatedInclusion, key) == true
        end
    end

    local replacementValuedCosts = 0
    replacementValuedCosts, reason = addMoney(
        replacementValuedCosts,
        selectedInputs,
        "replacementValuedCostsOutOfRange",
        policy
    )
    if replacementValuedCosts == nil then
        return nil, reason
    end
    replacementValuedCosts, reason = addMoney(
        replacementValuedCosts,
        selectedFuel,
        "replacementValuedCostsOutOfRange",
        policy
    )
    if replacementValuedCosts == nil then
        return nil, reason
    end
    replacementValuedCosts, reason = addMoney(
        replacementValuedCosts,
        selectedDef,
        "replacementValuedCostsOutOfRange",
        policy
    )
    if replacementValuedCosts == nil then
        return nil, reason
    end

    local totalSelectedCosts = 0
    totalSelectedCosts, reason = addMoney(
        totalSelectedCosts,
        selectedDirect,
        "selectedCostTotalOutOfRange",
        policy
    )
    if totalSelectedCosts == nil then
        return nil, reason
    end
    totalSelectedCosts, reason = addMoney(
        totalSelectedCosts,
        replacementValuedCosts,
        "selectedCostTotalOutOfRange",
        policy
    )
    if totalSelectedCosts == nil then
        return nil, reason
    end
    totalSelectedCosts, reason = addMoney(
        totalSelectedCosts,
        allocatedTotal,
        "selectedCostTotalOutOfRange",
        policy
    )
    if totalSelectedCosts == nil then
        return nil, reason
    end

    local margin
    margin, reason = checkedMoneyResult(
        estimatedValue - totalSelectedCosts,
        "estimatedGrossMarginOutOfRange",
        policy
    )
    if margin == nil then
        return nil, reason
    end

    return margin, {
        estimatedHarvestValue = estimatedValue,
        directObservedCosts = selectedDirect,
        replacementValuedInputs = selectedInputs,
        replacementFuelValue = selectedFuel,
        replacementDefValue = selectedDef,
        allocatedCosts = selectedAllocated,
        replacementValuedCosts = replacementValuedCosts,
        allocatedCostTotal = allocatedTotal,
        totalSelectedCosts = totalSelectedCosts,
        estimatedGrossMargin = margin,
        inclusion = {
            direct = includeDirect,
            inputs = includeInputs,
            fuel = includeFuel,
            def = includeDef,
            allocated = effectiveAllocatedInclusion
        }
    }
end

local function ratio(numerator, denominator, epsilon, specification)
    local acceptedNumerator, reason = checkedNumber(
        numerator,
        0,
        specification.numeratorMaximum,
        specification.numeratorPrefix
    )
    if acceptedNumerator == nil then
        return nil, reason
    end

    local acceptedDenominator
    acceptedDenominator, reason = checkedNumber(
        denominator,
        0,
        specification.denominatorMaximum,
        specification.denominatorPrefix
    )
    if acceptedDenominator == nil then
        return nil, reason
    end

    local acceptedEpsilon
    acceptedEpsilon, reason = checkedNumber(
        epsilon,
        0,
        specification.denominatorMaximum,
        "epsilon"
    )
    if acceptedEpsilon == nil then
        return nil, reason
    end

    if acceptedDenominator <= acceptedEpsilon then
        return nil, specification.smallReason
    end

    local result = acceptedNumerator / acceptedDenominator
    if not isFinite(result) then
        return nil, specification.resultReason
    end

    return result
end

function Accounting.yieldPerArea(quantity, area, epsilon)
    local policy, reason = resolvePolicy()
    if policy == nil then
        return nil, reason
    end
    return ratio(quantity, area, epsilon, {
        numeratorMaximum = policy.maxPhysical,
        numeratorPrefix = "quantity",
        denominatorMaximum = policy.maxAreaHa,
        denominatorPrefix = "area",
        smallReason = "areaNotAboveEpsilon",
        resultReason = "yieldPerAreaOutOfRange"
    })
end

function Accounting.costPerArea(cost, area, epsilon)
    local policy, reason = resolvePolicy()
    if policy == nil then
        return nil, reason
    end
    return ratio(cost, area, epsilon, {
        numeratorMaximum = policy.maxMoney,
        numeratorPrefix = "cost",
        denominatorMaximum = policy.maxAreaHa,
        denominatorPrefix = "area",
        smallReason = "areaNotAboveEpsilon",
        resultReason = "costPerAreaOutOfRange"
    })
end

function Accounting.costPerMass(cost, mass, epsilon)
    local policy, reason = resolvePolicy()
    if policy == nil then
        return nil, reason
    end
    return ratio(cost, mass, epsilon, {
        numeratorMaximum = policy.maxMoney,
        numeratorPrefix = "cost",
        denominatorMaximum = policy.maxPhysical,
        denominatorPrefix = "mass",
        smallReason = "massNotAboveEpsilon",
        resultReason = "costPerMassOutOfRange"
    })
end

function Accounting.leaseAllocation(storePrice, runningFactor, activeHours)
    local policy, reason = resolvePolicy()
    if policy == nil then
        return nil, reason
    end

    local acceptedPrice
    acceptedPrice, reason = checkedNumber(storePrice, 0, policy.maxMoney, "storePrice")
    if acceptedPrice == nil then
        return nil, reason
    end

    local acceptedFactor
    acceptedFactor, reason = checkedNumber(
        runningFactor,
        0,
        policy.maxMoney,
        "runningFactor"
    )
    if acceptedFactor == nil then
        return nil, reason
    end

    local acceptedHours
    acceptedHours, reason = checkedNumber(
        activeHours,
        0,
        policy.maxActiveHours,
        "activeHours"
    )
    if acceptedHours == nil then
        return nil, reason
    end

    return checkedNonNegativeMoneyResult(
        acceptedPrice * acceptedFactor * acceptedHours,
        "leaseAllocationOutOfRange",
        policy
    )
end

function Accounting.repairLiability(startPrice, endPrice)
    local policy, reason = resolvePolicy()
    if policy == nil then
        return nil, reason
    end

    local acceptedStart
    acceptedStart, reason = checkedNumber(
        startPrice,
        0,
        policy.maxMoney,
        "startRepairPrice"
    )
    if acceptedStart == nil then
        return nil, reason
    end

    local acceptedEnd
    acceptedEnd, reason = checkedNumber(
        endPrice,
        0,
        policy.maxMoney,
        "endRepairPrice"
    )
    if acceptedEnd == nil then
        return nil, reason
    end

    if acceptedEnd < acceptedStart then
        return nil, "repairDecreaseRebaseline"
    end

    return acceptedEnd - acceptedStart
end

function Accounting.ownershipAllocation(priceBasis, residualValue, usefulLifeHours, activeHours)
    local policy, reason = resolvePolicy()
    if policy == nil then
        return nil, reason
    end

    local acceptedBasis
    acceptedBasis, reason = checkedNumber(
        priceBasis,
        0,
        policy.maxMoney,
        "priceBasis"
    )
    if acceptedBasis == nil then
        return nil, reason
    end

    local acceptedResidual
    acceptedResidual, reason = checkedNumber(
        residualValue,
        0,
        policy.maxMoney,
        "residualValue"
    )
    if acceptedResidual == nil then
        return nil, reason
    end
    if acceptedResidual > acceptedBasis then
        return nil, "residualExceedsPriceBasis"
    end

    local acceptedLife
    acceptedLife, reason = checkedNumber(
        usefulLifeHours,
        0,
        policy.maxActiveHours,
        "usefulLifeHours"
    )
    if acceptedLife == nil then
        return nil, reason
    end
    if acceptedLife == 0 then
        return nil, "usefulLifeHoursNotPositive"
    end

    local acceptedHours
    acceptedHours, reason = checkedNumber(
        activeHours,
        0,
        policy.maxActiveHours,
        "activeHours"
    )
    if acceptedHours == nil then
        return nil, reason
    end

    return checkedNonNegativeMoneyResult(
        (acceptedBasis - acceptedResidual) / acceptedLife * acceptedHours,
        "ownershipAllocationOutOfRange",
        policy
    )
end

function Accounting.playerLabourAllocation(hourlyRate, playerActiveMs)
    local policy, reason = resolvePolicy()
    if policy == nil then
        return nil, reason
    end

    local acceptedRate
    acceptedRate, reason = checkedNumber(hourlyRate, 0, policy.maxMoney, "hourlyRate")
    if acceptedRate == nil then
        return nil, reason
    end

    local acceptedMs
    acceptedMs, reason = checkedNumber(
        playerActiveMs,
        0,
        policy.maxDurationMs,
        "playerActiveMs"
    )
    if acceptedMs == nil then
        return nil, reason
    end

    return checkedNonNegativeMoneyResult(
        acceptedRate * acceptedMs / 3600000,
        "playerLabourAllocationOutOfRange",
        policy
    )
end

local function allocationSum(allocations)
    local total = 0
    for i = 1, #allocations do
        total = total + allocations[i].amount
    end
    return total
end

local MIN_SUBNORMAL = math.ldexp(1, -1074)
local MIN_NORMAL = math.ldexp(1, -1022)

local function nextHigher(value)
    if value < MIN_NORMAL then
        return value + MIN_SUBNORMAL
    end

    local _, exponent = math.frexp(value)
    return value + math.ldexp(1, exponent - 53)
end

local function nextLower(value)
    if value <= 0 then
        return 0
    end
    if value <= MIN_NORMAL then
        return math.max(0, value - MIN_SUBNORMAL)
    end

    local mantissa, exponent = math.frexp(value)
    local step = math.ldexp(1, exponent - 53)
    if mantissa == 0.5 then
        step = step / 2
    end
    return math.max(0, value - step)
end

local function assignLowestRemainder(allocations, residualIndex, total, policy)
    local desiredPrefix = total

    -- Work backward so every later addition reconstructs its exact desired
    -- prefix. The lowest positive stable ID then receives the one remaining
    -- mathematical amount, while forward returned-order addition is exact.
    for i = #allocations, residualIndex + 1, -1 do
        local amount = allocations[i].amount
        if amount > desiredPrefix then
            amount = desiredPrefix
        end

        local assigned = false
        for _ = 1, 64 do
            local previousPrefix = desiredPrefix - amount
            local reconstructed = previousPrefix + amount
            if reconstructed == desiredPrefix then
                allocations[i].amount = amount
                desiredPrefix = previousPrefix
                assigned = true
                break
            end

            if reconstructed < desiredPrefix then
                amount = nextHigher(amount)
            else
                amount = nextLower(amount)
            end
            if amount > desiredPrefix then
                amount = desiredPrefix
            end
        end

        if not assigned then
            return nil, "allocationPrecisionFailure"
        end
    end

    for i = 1, residualIndex - 1 do
        allocations[i].amount = 0
    end
    if not isFinite(desiredPrefix) or desiredPrefix < 0
        or desiredPrefix > policy.maxMoney then
        return nil, "allocationPrecisionFailure"
    end
    allocations[residualIndex].amount = desiredPrefix

    if allocationSum(allocations) ~= total then
        return nil, "allocationPrecisionFailure"
    end

    return allocations
end

function Accounting.allocateByWeight(total, rows)
    local policy, reason = resolvePolicy()
    if policy == nil then
        return nil, reason
    end

    local acceptedTotal
    acceptedTotal, reason = checkedNumber(
        total,
        0,
        policy.maxMoney,
        "allocationTotal"
    )
    if acceptedTotal == nil then
        return nil, reason
    end

    local acceptedRows
    acceptedRows, reason = checkedArray(
        rows,
        policy.maxComponents,
        "invalidAllocationRows"
    )
    if acceptedRows == nil then
        return nil, reason
    end
    if #acceptedRows == 0 then
        return nil, "zeroTotalWeight"
    end

    local normalized = {}
    local seen = {}
    for i = 1, #acceptedRows do
        local row = acceptedRows[i]
        if type(row) ~= "table" or getmetatable(row) ~= nil then
            return nil, "invalidAllocationRow"
        end

        for key in next, row do
            if key ~= "id" and key ~= "weight" then
                return nil, "invalidAllocationRow"
            end
        end

        local id
        id, reason = checkedAscii(
            rawget(row, "id"),
            policy.idBytes,
            "invalidAllocationId"
        )
        if id == nil then
            return nil, reason
        end
        if seen[id] then
            return nil, "duplicateAllocationId"
        end
        seen[id] = true

        local weight
        weight, reason = checkedNumber(
            rawget(row, "weight"),
            0,
            policy.maxDurationMs,
            "allocationWeight"
        )
        if weight == nil then
            return nil, reason
        end

        normalized[#normalized + 1] = { id = id, weight = weight }
    end

    local identifierContract = identifiers()
    if identifierContract == nil then
        return nil, "identifiersUnavailable"
    end

    table.sort(normalized, function(left, right)
        return identifierContract.compare(left.id, right.id) < 0
    end)

    local totalWeight = 0
    for i = 1, #normalized do
        local nextWeight = totalWeight + normalized[i].weight
        if not isFinite(nextWeight) then
            return nil, "totalWeightOutOfRange"
        end
        totalWeight = nextWeight
    end
    if totalWeight <= 0 then
        return nil, "zeroTotalWeight"
    end

    local allocations = {}
    local residualIndex = nil
    for i = 1, #normalized do
        local row = normalized[i]
        local amount = acceptedTotal * (row.weight / totalWeight)
        if not isFinite(amount) or amount < 0 or amount > policy.maxMoney then
            return nil, "allocationAmountOutOfRange"
        end
        allocations[i] = { id = row.id, weight = row.weight, amount = amount }
        if residualIndex == nil and row.weight > 0 then
            residualIndex = i
        end
    end

    return assignLowestRemainder(
        allocations,
        residualIndex,
        acceptedTotal,
        policy
    )
end


local CONFIDENCE_KEYS = {
    applicable = true,
    reasons = true,
    items = true
}

local CONTRIBUTOR_KEYS = {
    qualityClass = true,
    usable = true,
    required = true,
    materiallyRejected = true,
    reasons = true
}

local function addReasons(reasonList, collected, seen, policy)
    local acceptedReasons, reason = checkedArray(
        reasonList,
        policy.maxReasons,
        "invalidConfidenceReasons"
    )
    if acceptedReasons == nil then
        return nil, reason
    end

    for i = 1, #acceptedReasons do
        local acceptedReason
        acceptedReason, reason = checkedAscii(
            acceptedReasons[i],
            policy.reasonBytes,
            "invalidConfidenceReason"
        )
        if acceptedReason == nil then
            return nil, reason
        end
        if not seen[acceptedReason] then
            if #collected >= policy.maxReasons then
                return nil, "tooManyConfidenceReasons"
            end
            seen[acceptedReason] = true
            collected[#collected + 1] = acceptedReason
        end
    end

    return true
end

function Accounting.confidence(contributors)
    local policy, reason = resolvePolicy()
    if policy == nil then
        return nil, reason
    end

    local accepted
    accepted, reason = validateKnownKeys(
        contributors,
        CONFIDENCE_KEYS,
        "invalidConfidenceContributors"
    )
    if accepted == nil then
        return nil, reason
    end

    local applicable = rawget(accepted, "applicable")
    if type(applicable) ~= "boolean" then
        return nil, "invalidConfidenceApplicability"
    end

    local items
    items, reason = checkedArray(
        rawget(accepted, "items"),
        policy.maxComponents,
        "invalidConfidenceItems"
    )
    if items == nil then
        return nil, reason
    end

    local collectedReasons = {}
    local seenReasons = {}
    local added
    added, reason = addReasons(
        rawget(accepted, "reasons"),
        collectedReasons,
        seenReasons,
        policy
    )
    if added == nil then
        return nil, reason
    end

    local usableCount = 0
    local hasUsablePartial = false
    local hasRequiredUnsupported = false
    local hasMaterialRejection = false

    for i = 1, #items do
        local item = items[i]
        local acceptedItem
        acceptedItem, reason = validateKnownKeys(
            item,
            CONTRIBUTOR_KEYS,
            "invalidConfidenceContributor"
        )
        if acceptedItem == nil then
            return nil, reason
        end

        local quality = rawget(acceptedItem, "qualityClass")
        if type(quality) ~= "string"
            or (quality ~= policy.qualityComplete
                and quality ~= policy.qualityPartial
                and quality ~= policy.qualityUnsupported) then
            return nil, "invalidContributorQuality"
        end

        local usable = rawget(acceptedItem, "usable")
        local required = rawget(acceptedItem, "required")
        local materiallyRejected = rawget(acceptedItem, "materiallyRejected")
        if type(usable) ~= "boolean" or type(required) ~= "boolean"
            or type(materiallyRejected) ~= "boolean" then
            return nil, "invalidConfidenceContributor"
        end
        if (quality == policy.qualityUnsupported and usable)
            or (quality ~= policy.qualityUnsupported and not usable) then
            return nil, "invalidContributorUsability"
        end

        local itemReasons = rawget(acceptedItem, "reasons")
        local acceptedItemReasons
        acceptedItemReasons, reason = checkedArray(
            itemReasons,
            policy.maxReasons,
            "invalidConfidenceReasons"
        )
        if acceptedItemReasons == nil then
            return nil, reason
        end
        if (quality ~= policy.qualityComplete or materiallyRejected)
            and #acceptedItemReasons == 0 then
            return nil, "missingConfidenceReason"
        end

        added, reason = addReasons(
            itemReasons,
            collectedReasons,
            seenReasons,
            policy
        )
        if added == nil then
            return nil, reason
        end

        if usable then
            usableCount = usableCount + 1
        end
        if usable and quality == policy.qualityPartial then
            hasUsablePartial = true
        end
        if required and quality == policy.qualityUnsupported then
            hasRequiredUnsupported = true
        end
        if materiallyRejected then
            hasMaterialRejection = true
        end
    end

    table.sort(collectedReasons, unsignedByteLess)

    if not applicable then
        return policy.confidenceNotApplicable, collectedReasons
    end
    if hasRequiredUnsupported or hasMaterialRejection or usableCount == 0 then
        if usableCount == 0 and not seenReasons.noUsableContributor then
            local generatedReason = checkedAscii(
                "noUsableContributor",
                policy.reasonBytes,
                "constantsUnavailable"
            )
            if generatedReason == nil then
                return nil, "constantsUnavailable"
            end
            if #collectedReasons >= policy.maxReasons then
                return nil, "tooManyConfidenceReasons"
            end
            collectedReasons[#collectedReasons + 1] = "noUsableContributor"
            table.sort(collectedReasons, unsignedByteLess)
        end
        return policy.confidenceLow, collectedReasons
    end
    if hasUsablePartial then
        return policy.confidenceMedium, collectedReasons
    end

    return policy.confidenceHigh, collectedReasons
end

FieldProfitabilityLedger.Core.Accounting = Accounting

return Accounting
