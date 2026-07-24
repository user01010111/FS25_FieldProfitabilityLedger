-- Exact, mergeable summation for accepted Lua binary64 values.
--
-- The accumulator stores a signed integer in units of 2^-1074.  Base-2^24
-- limbs keep every arithmetic intermediate below Lua binary64's exact-integer
-- ceiling.  It has no Farming Simulator or persistence dependency.

FieldProfitabilityLedger = FieldProfitabilityLedger or {}
FieldProfitabilityLedger.Core = FieldProfitabilityLedger.Core or {}

local ExactSum = {}

local VERSION = 1
local BASE_BITS = 24
local BASE = 16777216 -- 2^24
local TWO_TO_52 = 4503599627370496
local TWO_TO_53 = 9007199254740992
local HARD_MAX_TERMS = 1000000
local HARD_MAX_UNIT = 3153600000000
local MAX_LIMBS = 48

-- Public values are informational.  Mutating the module fields cannot change
-- the private constants used by the implementation.
ExactSum.VERSION = VERSION
ExactSum.BASE_BITS = BASE_BITS
ExactSum.MAX_LIMBS = MAX_LIMBS

local HANDLE_METATABLE = {
    __metatable = "FieldProfitabilityLedger.ExactSum"
}
local PRIVATE_STATES = setmetatable({}, {__mode = "k"})

local OUTER_KEYS = {
    limbs = true,
    sign = true,
    terms = true,
    version = true
}

local function currentCore()
    if type(FieldProfitabilityLedger) ~= "table" then
        return nil
    end
    local core = rawget(FieldProfitabilityLedger, "Core")
    if type(core) ~= "table" then
        return nil
    end
    return core
end

local function policyInteger(value, minimum, maximum)
    if type(value) ~= "number" or value ~= value
        or value == math.huge or value == -math.huge
        or value ~= math.floor(value) or value < minimum or value > maximum then
        return nil
    end
    return value
end

local function resolvePolicy()
    local core = currentCore()
    if core == nil then
        return nil, nil, "constantsUnavailable"
    end

    local validation = rawget(core, "Validation")
    if type(validation) ~= "table" or getmetatable(validation) ~= nil
        or type(rawget(validation, "isFinite")) ~= "function"
        or type(rawget(validation, "number")) ~= "function"
        or type(rawget(validation, "integer")) ~= "function" then
        return nil, nil, "validationUnavailable"
    end

    local constants = rawget(core, "Constants")
    if type(constants) ~= "table" or getmetatable(constants) ~= nil then
        return nil, nil, "constantsUnavailable"
    end
    local limits = rawget(constants, "LIMITS")
    if type(limits) ~= "table" or getmetatable(limits) ~= nil then
        return nil, nil, "constantsUnavailable"
    end

    local maxRecords = policyInteger(
        rawget(limits, "maxRecords"),
        0,
        HARD_MAX_TERMS
    )
    local maxPhysical = policyInteger(
        rawget(limits, "maxPhysical"),
        0,
        HARD_MAX_UNIT
    )
    local maxAreaHa = policyInteger(
        rawget(limits, "maxAreaHa"),
        0,
        HARD_MAX_UNIT
    )
    local maxMoney = policyInteger(
        rawget(limits, "maxMoney"),
        0,
        HARD_MAX_UNIT
    )
    local maxDurationMs = policyInteger(
        rawget(limits, "maxDurationMs"),
        0,
        HARD_MAX_UNIT
    )
    if maxRecords == nil or maxPhysical == nil or maxAreaHa == nil
        or maxMoney == nil or maxDurationMs == nil then
        return nil, nil, "constantsUnavailable"
    end

    if type(math.frexp) ~= "function" or type(math.ldexp) ~= "function" then
        return nil, nil, "exactSumMathUnavailable"
    end

    return {
        maxTerms = maxRecords,
        maxUnit = math.max(maxPhysical, maxAreaHa, maxMoney, maxDurationMs)
    }, validation
end

local function copyMagnitude(source)
    local result = {}
    for index = 1, #source do
        result[index] = source[index]
    end
    return result
end

local function trimMagnitude(magnitude)
    while #magnitude > 0 and magnitude[#magnitude] == 0 do
        magnitude[#magnitude] = nil
    end
    return magnitude
end

local function compareMagnitude(left, right)
    if #left < #right then
        return -1
    elseif #left > #right then
        return 1
    end
    for index = #left, 1, -1 do
        if left[index] < right[index] then
            return -1
        elseif left[index] > right[index] then
            return 1
        end
    end
    return 0
end

local function addMagnitude(left, right)
    local count = math.max(#left, #right)
    local result = {}
    local carry = 0
    for index = 1, count do
        local value = (left[index] or 0) + (right[index] or 0) + carry
        if value >= BASE then
            value = value - BASE
            carry = 1
        else
            carry = 0
        end
        result[index] = value
    end
    if carry ~= 0 then
        result[count + 1] = carry
    end
    return result
end

local function subtractMagnitude(left, right)
    -- The caller proves left >= right before entering this exact operation.
    local result = {}
    local borrow = 0
    for index = 1, #left do
        local value = left[index] - (right[index] or 0) - borrow
        if value < 0 then
            value = value + BASE
            borrow = 1
        else
            borrow = 0
        end
        result[index] = value
    end
    if borrow ~= 0 then
        return nil
    end
    return trimMagnitude(result)
end

local function multiplyMagnitudeSmall(source, multiplier)
    if multiplier == 0 or #source == 0 then
        return {}
    end
    local result = {}
    local carry = 0
    for index = 1, #source do
        local value = source[index] * multiplier + carry
        local quotient = math.floor(value / BASE)
        result[index] = value - quotient * BASE
        carry = quotient
    end
    while carry > 0 do
        local quotient = math.floor(carry / BASE)
        result[#result + 1] = carry - quotient * BASE
        carry = quotient
    end
    return trimMagnitude(result)
end

local function addShiftedChunk(magnitude, chunk, bitShift)
    if chunk == 0 then
        return true
    end
    local index = math.floor(bitShift / BASE_BITS) + 1
    if index > MAX_LIMBS then
        return nil
    end
    for fill = #magnitude + 1, index - 1 do
        magnitude[fill] = 0
    end

    local pending = chunk * 2 ^ (bitShift % BASE_BITS)
    while pending > 0 do
        if index > MAX_LIMBS then
            return nil
        end
        local quotient = math.floor(pending / BASE)
        local low = pending - quotient * BASE
        local value = (magnitude[index] or 0) + low
        if value >= BASE then
            value = value - BASE
            quotient = quotient + 1
        end
        magnitude[index] = value
        pending = quotient
        index = index + 1
    end
    return true
end

local function magnitudeFromDouble(value)
    if value == 0 then
        return {}
    end

    local fraction, exponent = math.frexp(value)
    local significand = fraction * TWO_TO_53
    if significand ~= math.floor(significand) then
        return nil
    end

    local bitShift = exponent + 1021
    if bitShift < 0 then
        significand = significand / 2 ^ (-bitShift)
        bitShift = 0
        if significand ~= math.floor(significand) then
            return nil
        end
    end

    local low = significand % BASE
    local middle = math.floor(significand / BASE) % BASE
    local high = math.floor(significand / (BASE * BASE))
    local result = {}
    if not addShiftedChunk(result, low, bitShift)
        or not addShiftedChunk(result, middle, bitShift + BASE_BITS)
        or not addShiftedChunk(result, high, bitShift + 2 * BASE_BITS) then
        return nil
    end
    return trimMagnitude(result)
end

local function combineSigned(leftSign, left, rightSign, right)
    if #left == 0 then
        if #right == 0 then
            return 0, {}
        end
        return rightSign, copyMagnitude(right)
    elseif #right == 0 then
        return leftSign, copyMagnitude(left)
    elseif leftSign == rightSign then
        return leftSign, addMagnitude(left, right)
    end

    local comparison = compareMagnitude(left, right)
    if comparison == 0 then
        return 0, {}
    elseif comparison > 0 then
        local difference = subtractMagnitude(left, right)
        if difference == nil then
            return nil, nil
        end
        return leftSign, difference
    end
    local difference = subtractMagnitude(right, left)
    if difference == nil then
        return nil, nil
    end
    return rightSign, difference
end

local function bitLengthSmall(value)
    local length = 0
    while value > 0 do
        value = math.floor(value / 2)
        length = length + 1
    end
    return length
end

local function bitLengthMagnitude(magnitude)
    if #magnitude == 0 then
        return 0
    end
    return (#magnitude - 1) * BASE_BITS
        + bitLengthSmall(magnitude[#magnitude])
end

local function magnitudeBit(magnitude, position)
    local limb = magnitude[math.floor(position / BASE_BITS) + 1] or 0
    return math.floor(limb / 2 ^ (position % BASE_BITS)) % 2
end

local function hasBitBelow(magnitude, exclusiveLimit)
    for position = 0, exclusiveLimit - 1 do
        if magnitudeBit(magnitude, position) ~= 0 then
            return true
        end
    end
    return false
end

local function makeHandle(state)
    local handle = setmetatable({}, HANDLE_METATABLE)
    PRIVATE_STATES[handle] = state
    return handle
end

local function stateFor(value)
    if type(value) ~= "table" then
        return nil
    end
    return PRIVATE_STATES[value]
end

local function configuredState(unitLimit, maxTerms)
    local policy, validation, dependencyReason = resolvePolicy()
    if policy == nil then
        return nil, dependencyReason
    end

    local acceptedUnit = validation.number(unitLimit, 0, policy.maxUnit)
    local acceptedTerms = validation.integer(maxTerms, 0, policy.maxTerms)
    if acceptedUnit == nil or acceptedTerms == nil then
        return nil, "invalidExactSumPolicy"
    end

    local unitMagnitude = magnitudeFromDouble(acceptedUnit)
    if unitMagnitude == nil then
        return nil, "invalidExactSumPolicy"
    end
    local workMagnitude = multiplyMagnitudeSmall(unitMagnitude, acceptedTerms)
    if #workMagnitude > MAX_LIMBS then
        return nil, "invalidExactSumPolicy"
    end

    return {
        unitLimit = acceptedUnit,
        maxTerms = acceptedTerms,
        terms = 0,
        sign = 0,
        limbs = {}
    }
end

local function validateLivePolicy(state)
    local policy, validation, dependencyReason = resolvePolicy()
    if policy == nil then
        return nil, nil, dependencyReason
    end
    local acceptedUnit = validation.number(state.unitLimit, 0, policy.maxUnit)
    local acceptedTerms = validation.integer(state.maxTerms, 0, policy.maxTerms)
    if acceptedUnit == nil or acceptedTerms == nil then
        return nil, nil, "invalidExactSumPolicy"
    end
    return policy, validation
end

local function validateNeutralStructure(value, state, validation)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        return nil, "invalidExactSumState"
    end

    local outerCount = 0
    for key in next, value do
        outerCount = outerCount + 1
        if outerCount > 4 or type(key) ~= "string" or #key > 7
            or rawget(OUTER_KEYS, key) ~= true then
            return nil, "invalidExactSumState"
        end
    end
    if outerCount ~= 4 then
        return nil, "invalidExactSumState"
    end

    if rawget(value, "version") ~= VERSION then
        return nil, "invalidExactSumState"
    end

    local terms = rawget(value, "terms")
    if not validation.isFinite(terms) or terms ~= math.floor(terms) or terms < 0 then
        return nil, "invalidExactSumState"
    end
    if terms > state.maxTerms then
        return nil, "exactSumTermLimit"
    end

    local sign = rawget(value, "sign")
    if not validation.isFinite(sign) or sign ~= math.floor(sign)
        or sign < -1 or sign > 1 then
        return nil, "invalidExactSumState"
    end

    local sourceLimbs = rawget(value, "limbs")
    if type(sourceLimbs) ~= "table" or getmetatable(sourceLimbs) ~= nil then
        return nil, "invalidExactSumState"
    end

    local limbCount = 0
    local seen = {}
    for key in next, sourceLimbs do
        limbCount = limbCount + 1
        if limbCount > MAX_LIMBS or not validation.isFinite(key)
            or key ~= math.floor(key) or key < 1 or key > MAX_LIMBS then
            return nil, "invalidExactSumState"
        end
        seen[key] = true
    end

    local limbs = {}
    for index = 1, limbCount do
        local limb = rawget(sourceLimbs, index)
        if not seen[index] or not validation.isFinite(limb)
            or limb ~= math.floor(limb) or limb < 0 or limb >= BASE then
            return nil, "invalidExactSumState"
        end
        limbs[index] = limb
    end

    if (limbCount == 0 and sign ~= 0)
        or (limbCount > 0 and (sign == 0 or limbs[limbCount] == 0)) then
        return nil, "nonCanonicalExactSum"
    end

    local unitMagnitude = magnitudeFromDouble(state.unitLimit)
    if unitMagnitude == nil then
        return nil, "invalidExactSumPolicy"
    end
    local actualBound = multiplyMagnitudeSmall(unitMagnitude, terms)
    if compareMagnitude(limbs, actualBound) > 0 then
        return nil, "exactSumMagnitudeOutOfRange"
    end

    return {
        terms = terms,
        sign = sign,
        limbs = limbs
    }
end

function ExactSum.new(unitLimit, maxTerms)
    local state, reason = configuredState(unitLimit, maxTerms)
    if state == nil then
        return nil, reason
    end
    return makeHandle(state)
end

function ExactSum.add(accumulator, value)
    local state = stateFor(accumulator)
    if state == nil then
        return nil, "invalidExactSumAccumulator"
    end
    local _, validation, policyReason = validateLivePolicy(state)
    if validation == nil then
        return nil, policyReason
    end
    if not validation.isFinite(value) or math.abs(value) > state.unitLimit then
        return nil, "exactSumTermOutOfRange"
    end
    if state.terms >= state.maxTerms then
        return nil, "exactSumTermLimit"
    end

    if value == 0 then
        state.terms = state.terms + 1
        return true
    end

    local magnitude = magnitudeFromDouble(math.abs(value))
    if magnitude == nil then
        return nil, "exactSumTermOutOfRange"
    end
    local sign, limbs = combineSigned(
        state.sign,
        state.limbs,
        value < 0 and -1 or 1,
        magnitude
    )
    if sign == nil or #limbs > MAX_LIMBS then
        return nil, "exactSumMagnitudeOutOfRange"
    end

    state.sign = sign
    state.limbs = limbs
    state.terms = state.terms + 1
    return true
end

function ExactSum.merge(accumulator, source)
    local targetState = stateFor(accumulator)
    if targetState == nil then
        return nil, "invalidExactSumAccumulator"
    end
    local _, validation, policyReason = validateLivePolicy(targetState)
    if validation == nil then
        return nil, policyReason
    end

    local sourceState = stateFor(source)
    local acceptedSource
    if sourceState ~= nil then
        local _, _, sourcePolicyReason = validateLivePolicy(sourceState)
        if sourcePolicyReason ~= nil then
            return nil, sourcePolicyReason
        end
        if sourceState.terms > targetState.maxTerms then
            return nil, "exactSumTermLimit"
        end
        local targetUnitMagnitude = magnitudeFromDouble(targetState.unitLimit)
        if targetUnitMagnitude == nil then
            return nil, "invalidExactSumPolicy"
        end
        local sourceBound = multiplyMagnitudeSmall(
            targetUnitMagnitude,
            sourceState.terms
        )
        if compareMagnitude(sourceState.limbs, sourceBound) > 0 then
            return nil, "exactSumMagnitudeOutOfRange"
        end
        acceptedSource = sourceState
    else
        acceptedSource, policyReason = validateNeutralStructure(
            source,
            targetState,
            validation
        )
        if acceptedSource == nil then
            return nil, policyReason
        end
    end

    local mergedTerms = targetState.terms + acceptedSource.terms
    if mergedTerms > targetState.maxTerms then
        return nil, "exactSumTermLimit"
    end
    local sign, limbs = combineSigned(
        targetState.sign,
        targetState.limbs,
        acceptedSource.sign,
        acceptedSource.limbs
    )
    if sign == nil or #limbs > MAX_LIMBS then
        return nil, "exactSumMagnitudeOutOfRange"
    end

    targetState.sign = sign
    targetState.limbs = limbs
    targetState.terms = mergedTerms
    return true
end

function ExactSum.finish(accumulator, resultLimit)
    local state = stateFor(accumulator)
    if state == nil then
        return nil, "invalidExactSumAccumulator"
    end
    local _, validation, policyReason = validateLivePolicy(state)
    if validation == nil then
        return nil, policyReason
    end
    local acceptedLimit = validation.number(resultLimit, 0, state.unitLimit)
    if acceptedLimit == nil then
        return nil, "invalidExactSumResultLimit"
    end

    local resultMagnitude = magnitudeFromDouble(acceptedLimit)
    if resultMagnitude == nil then
        return nil, "invalidExactSumResultLimit"
    end
    if compareMagnitude(state.limbs, resultMagnitude) > 0 then
        return nil, "aggregateOutOfRange"
    end
    if state.sign == 0 then
        return 0
    end

    local length = bitLengthMagnitude(state.limbs)
    local shift = math.max(0, length - 53)
    local significand = 0
    for position = length - 1, shift, -1 do
        significand = significand * 2 + magnitudeBit(state.limbs, position)
    end

    if shift > 0 then
        local guard = magnitudeBit(state.limbs, shift - 1)
        local sticky = hasBitBelow(state.limbs, shift - 1)
        if guard == 1 and (sticky or significand % 2 == 1) then
            significand = significand + 1
            if significand == TWO_TO_53 then
                significand = TWO_TO_52
                shift = shift + 1
            end
        end
    end

    local result = math.ldexp(significand, shift - 1074)
    if not validation.isFinite(result) then
        return nil, "aggregateOutOfRange"
    end
    if state.sign < 0 then
        return -result
    end
    return result
end

function ExactSum.toNeutral(accumulator)
    local state = stateFor(accumulator)
    if state == nil then
        return nil, "invalidExactSumAccumulator"
    end
    local _, validation, policyReason = validateLivePolicy(state)
    if validation == nil then
        return nil, policyReason
    end
    return {
        version = VERSION,
        terms = state.terms,
        sign = state.sign,
        limbs = copyMagnitude(state.limbs)
    }
end

function ExactSum.fromNeutral(value, unitLimit, maxTerms)
    local state, reason = configuredState(unitLimit, maxTerms)
    if state == nil then
        return nil, reason
    end
    local _, validation, policyReason = validateLivePolicy(state)
    if validation == nil then
        return nil, policyReason
    end

    local accepted
    accepted, reason = validateNeutralStructure(value, state, validation)
    if accepted == nil then
        return nil, reason
    end
    state.terms = accepted.terms
    state.sign = accepted.sign
    state.limbs = accepted.limbs
    return makeHandle(state)
end

FieldProfitabilityLedger.Core.ExactSum = ExactSum

return ExactSum
