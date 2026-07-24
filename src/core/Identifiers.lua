FieldProfitabilityLedger = FieldProfitabilityLedger or {}
FieldProfitabilityLedger.Core = FieldProfitabilityLedger.Core or {}

local Identifiers = {}

local MAX_SAFE_INTEGER = 9007199254740991

local function getIdentifierLimits()
    local constants = rawget(FieldProfitabilityLedger.Core, "Constants")
    if type(constants) ~= "table" then
        return nil, "constantsUnavailable"
    end

    local limits = rawget(constants, "LIMITS")
    if type(limits) ~= "table" then
        return nil, "constantsUnavailable"
    end

    local idBytes = rawget(limits, "idBytes")
    if type(idBytes) ~= "number"
        or idBytes ~= idBytes
        or idBytes == math.huge
        or idBytes == -math.huge
        or idBytes < 1
        or idBytes ~= math.floor(idBytes) then
        return nil, "constantsUnavailable"
    end

    local maxIdentifier = rawget(limits, "maxIdentifier")
    if type(maxIdentifier) ~= "number"
        or maxIdentifier ~= maxIdentifier
        or maxIdentifier == math.huge
        or maxIdentifier == -math.huge
        or maxIdentifier < 1
        or maxIdentifier > MAX_SAFE_INTEGER
        or maxIdentifier ~= math.floor(maxIdentifier) then
        return nil, "constantsUnavailable"
    end

    return idBytes, maxIdentifier
end

local function getValidation()
    local validation = rawget(FieldProfitabilityLedger.Core, "Validation")
    if type(validation) ~= "table"
        or type(validation.integer) ~= "function"
        or type(validation.asciiToken) ~= "function" then
        return nil, "validationUnavailable"
    end
    return validation
end

local function validatePositiveInteger(value, validation, maxIdentifier)
    return validation.integer(value, 1, maxIdentifier)
end

local function integerText(value)
    return string.format("%.0f", value)
end

local function parsePositiveInteger(text, maxIdentifier)
    if type(text) ~= "string"
        or not string.match(text, "^[1-9][0-9]*$")
        or #text > 16 then
        return nil
    end

    local value = tonumber(text)
    if type(value) ~= "number"
        or value ~= value
        or value == math.huge
        or value == -math.huge
        or value < 1
        or value > MAX_SAFE_INTEGER
        or value > maxIdentifier
        or value ~= math.floor(value)
        or integerText(value) ~= text then
        return nil
    end

    return value
end

local function validateKind(kind, validation, idBytes)
    local accepted, reason = validation.asciiToken(kind, idBytes)
    if accepted == nil then
        return nil, reason
    end
    if not string.match(accepted, "^[A-Za-z][A-Za-z0-9_-]*$") then
        return nil, "invalidKind"
    end
    return accepted
end

local function validateFinalId(value, validation, idBytes)
    return validation.asciiToken(value, idBytes)
end

local function escapeComponent(value)
    local parts = {}
    for index = 1, #value do
        local byte = string.byte(value, index)
        local safe = (byte >= 48 and byte <= 57)
            or (byte >= 65 and byte <= 90)
            or (byte >= 97 and byte <= 122)
            or byte == 45
            or byte == 46
            or byte == 95
        if safe then
            parts[#parts + 1] = string.char(byte)
        else
            parts[#parts + 1] = string.format("%%%02X", byte)
        end
    end
    return table.concat(parts)
end

local function unescapeComponent(value, validation, idBytes)
    if type(value) ~= "string" or value == "" then
        return nil, "invalidObservationId"
    end
    local parts = {}
    local index = 1
    while index <= #value do
        local byte = string.byte(value, index)
        if byte == 37 then
            local hex = string.sub(value, index + 1, index + 2)
            if #hex ~= 2 or not string.match(hex, "^[0-9A-F][0-9A-F]$") then
                return nil, "invalidObservationId"
            end
            parts[#parts + 1] = string.char(tonumber(hex, 16))
            index = index + 3
        else
            local safe = (byte >= 48 and byte <= 57)
                or (byte >= 65 and byte <= 90)
                or (byte >= 97 and byte <= 122)
                or byte == 45
                or byte == 46
                or byte == 95
            if not safe then
                return nil, "invalidObservationId"
            end
            parts[#parts + 1] = string.char(byte)
            index = index + 1
        end
    end
    local decoded = table.concat(parts)
    local accepted = validation.asciiToken(decoded, idBytes)
    if accepted == nil then
        return nil, "invalidObservationId"
    end
    return accepted
end

function Identifiers.landKey(farmId, farmlandId, fieldIdOrNil, ...)
    if select("#", ...) ~= 0 then
        return nil, "unexpectedArgument"
    end

    local idBytes, maxIdentifier = getIdentifierLimits()
    if idBytes == nil then
        return nil, maxIdentifier
    end
    local validation, reason = getValidation()
    if validation == nil then
        return nil, reason
    end

    local acceptedFarm
    acceptedFarm, reason = validatePositiveInteger(farmId, validation, maxIdentifier)
    if acceptedFarm == nil then
        return nil, reason
    end

    local acceptedFarmland
    acceptedFarmland, reason = validatePositiveInteger(farmlandId, validation, maxIdentifier)
    if acceptedFarmland == nil then
        return nil, reason
    end

    local fieldPart = "parcel"
    if fieldIdOrNil ~= nil then
        local acceptedField
        acceptedField, reason = validatePositiveInteger(
            fieldIdOrNil,
            validation,
            maxIdentifier
        )
        if acceptedField == nil then
            return nil, reason
        end
        fieldPart = "base-" .. integerText(acceptedField)
    end

    local key = "farm:" .. integerText(acceptedFarm)
        .. "/farmland:" .. integerText(acceptedFarmland)
        .. "/field:" .. fieldPart
    return validateFinalId(key, validation, idBytes)
end

function Identifiers.parseLandKey(key)
    local idBytes, maxIdentifier = getIdentifierLimits()
    if idBytes == nil then
        return nil, maxIdentifier
    end
    local validation, reason = getValidation()
    if validation == nil then
        return nil, reason
    end

    local accepted
    accepted, reason = validation.asciiToken(key, idBytes)
    if accepted == nil then
        return nil, reason
    end

    local farmText, farmlandText, fieldPart = string.match(
        accepted,
        "^farm:([1-9][0-9]*)/farmland:([1-9][0-9]*)/field:([A-Za-z0-9-]+)$"
    )
    if farmText == nil then
        return nil, "invalidLandKey"
    end

    local farmId = parsePositiveInteger(farmText, maxIdentifier)
    local farmlandId = parsePositiveInteger(farmlandText, maxIdentifier)
    if farmId == nil or farmlandId == nil then
        return nil, "invalidLandKey"
    end

    if fieldPart == "parcel" then
        return {
            farmId = farmId,
            farmlandId = farmlandId,
            fieldId = nil,
            fieldKind = "parcel",
            fieldPart = "parcel"
        }
    end

    local fieldText = string.match(fieldPart, "^base%-([1-9][0-9]*)$")
    local fieldId = parsePositiveInteger(fieldText, maxIdentifier)
    if fieldId == nil then
        return nil, "invalidLandKey"
    end

    return {
        farmId = farmId,
        farmlandId = farmlandId,
        fieldId = fieldId,
        fieldKind = "base",
        fieldPart = "base-" .. integerText(fieldId)
    }
end

function Identifiers.recordId(kind, numericId, ...)
    if select("#", ...) ~= 0 then
        return nil, "unexpectedArgument"
    end

    local idBytes, maxIdentifier = getIdentifierLimits()
    if idBytes == nil then
        return nil, maxIdentifier
    end
    local validation, reason = getValidation()
    if validation == nil then
        return nil, reason
    end

    local acceptedKind
    acceptedKind, reason = validateKind(kind, validation, idBytes)
    if acceptedKind == nil then
        return nil, reason
    end

    local acceptedNumericId
    acceptedNumericId, reason = validatePositiveInteger(
        numericId,
        validation,
        maxIdentifier
    )
    if acceptedNumericId == nil then
        return nil, reason
    end

    return validateFinalId(
        acceptedKind .. ":" .. integerText(acceptedNumericId),
        validation,
        idBytes
    )
end

function Identifiers.parseRecordId(id, expectedKindOrNil)
    local idBytes, maxIdentifier = getIdentifierLimits()
    if idBytes == nil then
        return nil, maxIdentifier
    end
    local validation, reason = getValidation()
    if validation == nil then
        return nil, reason
    end

    local expectedKind
    if expectedKindOrNil ~= nil then
        expectedKind, reason = validateKind(expectedKindOrNil, validation, idBytes)
        if expectedKind == nil then
            return nil, reason
        end
    end

    local accepted
    accepted, reason = validation.asciiToken(id, idBytes)
    if accepted == nil then
        return nil, reason
    end

    local kind, numericText = string.match(
        accepted,
        "^([A-Za-z][A-Za-z0-9_-]*):([1-9][0-9]*)$"
    )
    if kind == nil then
        return nil, "invalidRecordId"
    end

    local numericId = parsePositiveInteger(numericText, maxIdentifier)
    if numericId == nil then
        return nil, "invalidRecordId"
    end
    if expectedKind ~= nil and kind ~= expectedKind then
        return nil, "unexpectedKind"
    end

    return kind, numericId
end

function Identifiers.observationId(epoch, vehicleUniqueId, sequence, discriminator, ...)
    if select("#", ...) ~= 0 then
        return nil, "unexpectedArgument"
    end

    local idBytes, maxIdentifier = getIdentifierLimits()
    if idBytes == nil then
        return nil, maxIdentifier
    end
    local validation, reason = getValidation()
    if validation == nil then
        return nil, reason
    end

    local acceptedEpoch
    acceptedEpoch, reason = validatePositiveInteger(epoch, validation, maxIdentifier)
    if acceptedEpoch == nil then
        return nil, reason
    end

    local acceptedVehicle
    acceptedVehicle, reason = validation.asciiToken(vehicleUniqueId, idBytes)
    if acceptedVehicle == nil then
        return nil, reason
    end

    local acceptedSequence
    acceptedSequence, reason = validatePositiveInteger(
        sequence,
        validation,
        maxIdentifier
    )
    if acceptedSequence == nil then
        return nil, reason
    end

    local acceptedDiscriminator
    acceptedDiscriminator, reason = validation.asciiToken(discriminator, idBytes)
    if acceptedDiscriminator == nil then
        return nil, reason
    end

    local id = "obs:" .. integerText(acceptedEpoch)
        .. ":" .. escapeComponent(acceptedVehicle)
        .. ":" .. integerText(acceptedSequence)
        .. ":" .. escapeComponent(acceptedDiscriminator)
    return validateFinalId(id, validation, idBytes)
end

function Identifiers.parseObservationId(id)
    local idBytes, maxIdentifier = getIdentifierLimits()
    if idBytes == nil then
        return nil, maxIdentifier
    end
    local validation, reason = getValidation()
    if validation == nil then
        return nil, reason
    end

    local accepted = validation.asciiToken(id, idBytes)
    if accepted == nil then
        return nil, "invalidObservationId"
    end
    local epochText, vehicleText, sequenceText, discriminatorText = string.match(
        accepted,
        "^obs:([1-9][0-9]*):([^:]+):([1-9][0-9]*):([^:]+)$"
    )
    if epochText == nil then
        return nil, "invalidObservationId"
    end
    local epoch = parsePositiveInteger(epochText, maxIdentifier)
    local sequence = parsePositiveInteger(sequenceText, maxIdentifier)
    if epoch == nil or sequence == nil then
        return nil, "invalidObservationId"
    end
    local vehicleUniqueId = unescapeComponent(vehicleText, validation, idBytes)
    local discriminator = unescapeComponent(discriminatorText, validation, idBytes)
    if vehicleUniqueId == nil or discriminator == nil then
        return nil, "invalidObservationId"
    end
    local canonical = Identifiers.observationId(
        epoch,
        vehicleUniqueId,
        sequence,
        discriminator
    )
    if canonical ~= accepted then
        return nil, "invalidObservationId"
    end
    return {
        epoch = epoch,
        vehicleUniqueId = vehicleUniqueId,
        sequence = sequence,
        discriminator = discriminator
    }
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

local TYPE_ORDER = {
    ["nil"] = 1,
    boolean = 2,
    number = 3,
    string = 4,
    table = 5,
    ["function"] = 6,
    thread = 7,
    userdata = 8
}

function Identifiers.compare(left, right)
    if rawequal(left, right) then
        return 0
    end

    local leftType = type(left)
    local rightType = type(right)
    if leftType ~= rightType then
        if TYPE_ORDER[leftType] < TYPE_ORDER[rightType] then
            return -1
        end
        return 1
    end

    if leftType == "string" then
        local leftKind, leftNumericId = Identifiers.parseRecordId(left)
        local rightKind, rightNumericId = Identifiers.parseRecordId(right)
        local leftIsRecord = leftKind ~= nil
        local rightIsRecord = rightKind ~= nil

        -- Canonical records form one ranked partition before every other
        -- string. Without this partition, pairwise numeric-vs-byte fallback
        -- can create cycles across two records and one ordinary string.
        if leftIsRecord ~= rightIsRecord then
            if leftIsRecord then
                return -1
            end
            return 1
        elseif leftIsRecord then
            if leftNumericId < rightNumericId then
                return -1
            elseif leftNumericId > rightNumericId then
                return 1
            end
            return compareBytes(leftKind, rightKind)
        end
        return compareBytes(left, right)
    elseif leftType == "number" then
        local leftFinite = left == left and left ~= math.huge and left ~= -math.huge
        local rightFinite = right == right and right ~= math.huge and right ~= -math.huge
        if leftFinite and rightFinite then
            if left < right then
                return -1
            end
            return 1
        elseif leftFinite then
            return -1
        elseif rightFinite then
            return 1
        end
        return 0
    elseif leftType == "boolean" then
        if left == false then
            return -1
        end
        return 1
    end

    -- Composite values are not valid IDs. Treat distinct values of the same
    -- unsupported type as equivalent rather than ordering by process address.
    return 0
end

FieldProfitabilityLedger.Core.Identifiers = Identifiers

return Identifiers
