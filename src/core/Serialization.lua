FieldProfitabilityLedger = FieldProfitabilityLedger or {}
FieldProfitabilityLedger.Core = FieldProfitabilityLedger.Core or {}

local Serialization = {}

local MAX_FINITE = 1.7976931348623157e308
local TWO_TO_53 = 9007199254740992
local MAX_SAFE_INTEGER = 9007199254740991

local DEFAULT_LIMITS = {
    maxEncodedBytes = 8 * 1024 * 1024,
    maxDepth = 64,
    maxItems = 100000,
    maxStringBytes = 128,
    maxNumber = MAX_FINITE
}

local HARD_LIMITS = {
    maxEncodedBytes = 64 * 1024 * 1024,
    maxDepth = 256,
    maxItems = 1000000,
    maxStringBytes = 1024 * 1024
}

local LIMIT_FIELDS = {
    maxDepth = true,
    maxEncodedBytes = true,
    maxItems = true,
    maxNumber = true,
    maxStringBytes = true
}

-- Public copies are informational.  Mutating them cannot weaken the private
-- limits used by the implementation.
Serialization.DEFAULT_LIMITS = {
    maxEncodedBytes = DEFAULT_LIMITS.maxEncodedBytes,
    maxDepth = DEFAULT_LIMITS.maxDepth,
    maxItems = DEFAULT_LIMITS.maxItems,
    maxStringBytes = DEFAULT_LIMITS.maxStringBytes,
    maxNumber = DEFAULT_LIMITS.maxNumber
}
Serialization.HARD_LIMITS = {
    maxEncodedBytes = HARD_LIMITS.maxEncodedBytes,
    maxDepth = HARD_LIMITS.maxDepth,
    maxItems = HARD_LIMITS.maxItems,
    maxStringBytes = HARD_LIMITS.maxStringBytes
}

local function isFinite(value)
    return type(value) == "number"
        and value == value
        and value > -math.huge
        and value < math.huge
end

local function isInteger(value)
    return isFinite(value) and value == math.floor(value)
end

local function resolveLimits(limits)
    if limits ~= nil and type(limits) ~= "table" then
        return nil, "invalid_limits"
    end
    if limits ~= nil and getmetatable(limits) ~= nil then
        return nil, "invalid_limits"
    end
    if limits ~= nil then
        local key
        for key in next, limits do
            if type(key) ~= "string" or not LIMIT_FIELDS[key] then
                return nil, "invalid_limits"
            end
        end
    end

    local resolved = {}
    local integerFields = {
        { "maxEncodedBytes", 1, HARD_LIMITS.maxEncodedBytes },
        { "maxDepth", 0, HARD_LIMITS.maxDepth },
        { "maxItems", 1, HARD_LIMITS.maxItems },
        { "maxStringBytes", 0, HARD_LIMITS.maxStringBytes }
    }

    local index
    for index = 1, #integerFields do
        local definition = integerFields[index]
        local name = definition[1]
        local value = limits ~= nil and rawget(limits, name) or nil
        if value == nil then
            value = DEFAULT_LIMITS[name]
        end
        if not isInteger(value) or value < definition[2] or value > definition[3] then
            return nil, "invalid_limits"
        end
        resolved[name] = value
    end

    resolved.maxNumber = limits ~= nil and rawget(limits, "maxNumber") or nil
    if resolved.maxNumber == nil then
        resolved.maxNumber = DEFAULT_LIMITS.maxNumber
    end
    if not isFinite(resolved.maxNumber) or resolved.maxNumber < 0 then
        return nil, "invalid_limits"
    end

    return resolved
end

local function integerString(value)
    return string.format("%.0f", value)
end

local function compareByteStrings(left, right)
    local sharedLength = math.min(#left, #right)
    local index
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

local function byteStringLess(left, right)
    return compareByteStrings(left, right) < 0
end

-- This is an exact, locale-independent binary scientific spelling.  Every
-- finite Lua number is represented by an odd integer significand and a base-2
-- exponent.  It avoids locale-sensitive decimal parsing and preserves every
-- IEEE-754 double bit pattern except the deliberately canonicalized -0.
local function numberToken(value)
    if value == 0 then
        return "0"
    end

    local negative = value < 0
    local magnitude = negative and -value or value
    local fraction, exponent = math.frexp(magnitude)
    local significand = fraction * TWO_TO_53
    exponent = exponent - 53

    while significand % 2 == 0 do
        significand = significand / 2
        exponent = exponent + 1
    end

    local prefix = negative and "-" or ""
    return prefix .. integerString(significand) .. "p" .. string.format("%d", exponent)
end

local KEY_TYPE_RANK = {
    boolean = 1,
    number = 2,
    string = 3
}

local function keyLess(left, right)
    local leftType = type(left)
    local rightType = type(right)
    local leftRank = KEY_TYPE_RANK[leftType]
    local rightRank = KEY_TYPE_RANK[rightType]
    if leftRank ~= rightRank then
        return leftRank < rightRank
    end
    if leftType == "boolean" then
        return left == false and right == true
    elseif leftType == "number" then
        return left < right
    end
    return byteStringLess(left, right)
end

local function collectSortedKeys(value, maximumItems, maximumStringBytes)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        return nil, "invalid_table"
    end

    local keys = {}
    local oversizedString = false
    local key
    for key in next, value do
        if #keys >= maximumItems then
            return nil, "items_limit"
        end
        local keyType = type(key)
        if KEY_TYPE_RANK[keyType] == nil then
            return nil, "invalid_table_key"
        end
        if keyType == "number" and not isFinite(key) then
            return nil, "invalid_table_key"
        elseif keyType == "string" and #key > maximumStringBytes then
            oversizedString = true
        end
        keys[#keys + 1] = key
    end
    if oversizedString then
        return nil, "string_limit"
    end

    table.sort(keys, keyLess)

    return keys
end

function Serialization.sortedKeys(value)
    return collectSortedKeys(
        value,
        HARD_LIMITS.maxItems,
        HARD_LIMITS.maxStringBytes
    )
end

local function classifyTable(
    value,
    remainingItems,
    maximumArrayIndex,
    maximumStringBytes
)
    if getmetatable(value) ~= nil then
        return nil, nil, "metatable"
    end

    local numericCount = 0
    local oversizedString = false
    local stringCount = 0
    local maximumIndex = 0
    local key
    for key in next, value do
        if numericCount + stringCount >= remainingItems then
            return nil, nil, "items_limit"
        end
        local keyType = type(key)
        if keyType == "number" then
            if not isInteger(key) or key < 1 then
                return nil, nil, "invalid_array_index"
            end
            numericCount = numericCount + 1
            if key > maximumIndex then
                maximumIndex = key
            end
        elseif keyType == "string" then
            stringCount = stringCount + 1
            if #key > maximumStringBytes then
                oversizedString = true
            end
        else
            return nil, nil, "invalid_table_key"
        end
    end

    if numericCount > 0 and stringCount > 0 then
        return nil, nil, "mixed_table"
    end
    if numericCount > 0 then
        if maximumIndex > maximumArrayIndex then
            return nil, nil, "items_limit"
        end
        if maximumIndex ~= numericCount then
            return nil, nil, "sparse_array"
        end
        return "array", numericCount
    end
    if stringCount > 0 then
        if oversizedString then
            return nil, nil, "string_limit"
        end
        return "map", stringCount
    end

    -- An empty plain Lua table has no intrinsic array/map identity.  The
    -- canonical neutral interpretation is an empty array.
    return "array", 0
end

local function validateNumber(value, limits)
    if not isFinite(value) then
        return nil, "non_finite"
    end
    if value < -limits.maxNumber or value > limits.maxNumber then
        return nil, "number_bounds"
    end
    if value == 0 then
        return 0
    end
    return value
end

function Serialization.encode(value, limits)
    local resolved, limitReason = resolveLimits(limits)
    if resolved == nil then
        return nil, limitReason
    end

    local state = {
        active = {},
        bytes = 0,
        chunks = {},
        items = 0,
        seen = {}
    }

    local function append(chunk)
        local newSize = state.bytes + #chunk
        if newSize > resolved.maxEncodedBytes then
            return nil, "bytes_limit"
        end
        state.bytes = newSize
        state.chunks[#state.chunks + 1] = chunk
        return true
    end

    local encodeValue
    encodeValue = function(current, depth)
        if depth > resolved.maxDepth then
            return nil, "depth_limit"
        end
        state.items = state.items + 1
        if state.items > resolved.maxItems then
            return nil, "items_limit"
        end

        local valueType = type(current)
        if valueType == "nil" then
            return append("n")
        elseif valueType == "boolean" then
            return append(current and "b1" or "b0")
        elseif valueType == "number" then
            local normalized, numberReason = validateNumber(current, resolved)
            if normalized == nil then
                return nil, numberReason
            end
            return append("d" .. numberToken(normalized) .. ";")
        elseif valueType == "string" then
            if #current > resolved.maxStringBytes then
                return nil, "string_limit"
            end
            return append("s" .. integerString(#current) .. ":" .. current)
        elseif valueType ~= "table" then
            return nil, "unsupported_type"
        end

        if state.seen[current] then
            if state.active[current] then
                return nil, "cycle"
            end
            return nil, "shared_reference"
        end
        state.seen[current] = true
        state.active[current] = true

        local remainingItems = resolved.maxItems - state.items
        local tableKind, count, tableReason = classifyTable(
            current,
            remainingItems,
            resolved.maxItems,
            resolved.maxStringBytes
        )
        if tableKind == nil then
            return nil, tableReason
        end

        local ok, reason
        if tableKind == "array" then
            ok, reason = append("a" .. integerString(count) .. ":")
            if not ok then
                return nil, reason
            end
            local index
            for index = 1, count do
                ok, reason = encodeValue(rawget(current, index), depth + 1)
                if not ok then
                    return nil, reason
                end
            end
        else
            ok, reason = append("m" .. integerString(count) .. ":")
            if not ok then
                return nil, reason
            end
            local keys, keyReason = collectSortedKeys(
                current,
                remainingItems,
                resolved.maxStringBytes
            )
            if keys == nil then
                return nil, keyReason
            end
            local index
            for index = 1, #keys do
                local mapKey = keys[index]
                if type(mapKey) ~= "string" then
                    return nil, "invalid_table_key"
                end
                if #mapKey > resolved.maxStringBytes then
                    return nil, "string_limit"
                end
                ok, reason = append("s" .. integerString(#mapKey) .. ":" .. mapKey)
                if not ok then
                    return nil, reason
                end
                ok, reason = encodeValue(rawget(current, mapKey), depth + 1)
                if not ok then
                    return nil, reason
                end
            end
        end

        state.active[current] = nil
        return true
    end

    local ok, reason = encodeValue(value, 0)
    if not ok then
        return nil, reason
    end
    return table.concat(state.chunks)
end

local function parseCanonicalUnsigned(text, maximum)
    if #text == 0 then
        return nil
    end
    if #text > 1 and string.byte(text, 1) == 48 then
        return nil
    end

    local value = 0
    local index
    for index = 1, #text do
        local byte = string.byte(text, index)
        if byte < 48 or byte > 57 then
            return nil
        end
        value = value * 10 + (byte - 48)
        if value > maximum then
            return nil, "too_large"
        end
    end
    return value
end

local function decodeNumberToken(token, limits)
    if token == "0" then
        return 0
    end
    if #token == 0 or #token > 32 then
        return nil, "invalid_syntax"
    end

    local negative = false
    local start = 1
    if string.sub(token, 1, 1) == "-" then
        negative = true
        start = 2
    end

    local separator = string.find(token, "p", start, true)
    if separator == nil
        or separator == start
        or string.find(token, "p", separator + 1, true) ~= nil then
        return nil, "invalid_syntax"
    end

    local significandText = string.sub(token, start, separator - 1)
    local exponentText = string.sub(token, separator + 1)
    local significand, significandReason = parseCanonicalUnsigned(
        significandText,
        MAX_SAFE_INTEGER
    )
    if significand == nil
        or significandReason ~= nil
        or significand == 0
        or significand % 2 == 0 then
        return nil, "invalid_syntax"
    end

    local exponentNegative = false
    if string.sub(exponentText, 1, 1) == "-" then
        exponentNegative = true
        exponentText = string.sub(exponentText, 2)
    elseif string.sub(exponentText, 1, 1) == "+" then
        return nil, "invalid_syntax"
    end
    local exponent, exponentReason = parseCanonicalUnsigned(exponentText, 1074)
    if exponent == nil or exponentReason ~= nil then
        return nil, "invalid_syntax"
    end
    if exponentNegative then
        if exponent == 0 then
            return nil, "invalid_syntax"
        end
        exponent = -exponent
    elseif exponent > 1023 then
        return nil, "invalid_syntax"
    end

    local value = math.ldexp(significand, exponent)
    if negative then
        value = -value
    end
    if not isFinite(value) then
        return nil, "non_finite"
    end
    if numberToken(value) ~= token then
        return nil, "invalid_syntax"
    end
    if value < -limits.maxNumber or value > limits.maxNumber then
        return nil, "number_bounds"
    end
    return value
end

function Serialization.decode(encoded, limits)
    local resolved, limitReason = resolveLimits(limits)
    if resolved == nil then
        return nil, limitReason
    end
    if type(encoded) ~= "string" then
        return nil, "invalid_input"
    end
    if #encoded > resolved.maxEncodedBytes then
        return nil, "bytes_limit"
    end
    if #encoded == 0 then
        return nil, "truncated"
    end

    local position = 1
    local length = #encoded
    local itemCount = 0

    local function readUnsigned(delimiterByte, maximum, tooLargeReason)
        if position > length then
            return nil, "truncated"
        end
        local start = position
        local value = 0
        while position <= length do
            local byte = string.byte(encoded, position)
            if byte == delimiterByte then
                if position == start then
                    return nil, "invalid_syntax"
                end
                if position - start > 1 and string.byte(encoded, start) == 48 then
                    return nil, "invalid_syntax"
                end
                position = position + 1
                return value
            end
            if byte < 48 or byte > 57 then
                return nil, "invalid_syntax"
            end
            value = value * 10 + (byte - 48)
            if value > maximum then
                return nil, tooLargeReason
            end
            position = position + 1
        end
        return nil, "truncated"
    end

    local function readStringBody()
        local stringLength, reason = readUnsigned(58, resolved.maxStringBytes, "string_limit")
        if stringLength == nil then
            return nil, reason
        end
        if length - position + 1 < stringLength then
            return nil, "truncated"
        end
        local result = string.sub(encoded, position, position + stringLength - 1)
        position = position + stringLength
        return result
    end

    local parseValue
    parseValue = function(depth, nilAllowed)
        if depth > resolved.maxDepth then
            return nil, "depth_limit"
        end
        itemCount = itemCount + 1
        if itemCount > resolved.maxItems then
            return nil, "items_limit"
        end
        if position > length then
            return nil, "truncated"
        end

        local tag = string.sub(encoded, position, position)
        position = position + 1
        if tag == "n" then
            if not nilAllowed then
                return nil, "invalid_syntax"
            end
            return nil
        elseif tag == "b" then
            if position > length then
                return nil, "truncated"
            end
            local booleanByte = string.byte(encoded, position)
            position = position + 1
            if booleanByte == 48 then
                return false
            elseif booleanByte == 49 then
                return true
            end
            return nil, "invalid_syntax"
        elseif tag == "d" then
            local start = position
            while position <= length and string.byte(encoded, position) ~= 59 do
                position = position + 1
                if position - start > 32 then
                    return nil, "invalid_syntax"
                end
            end
            if position > length then
                return nil, "truncated"
            end
            local token = string.sub(encoded, start, position - 1)
            position = position + 1
            return decodeNumberToken(token, resolved)
        elseif tag == "s" then
            return readStringBody()
        elseif tag ~= "a" and tag ~= "m" then
            return nil, "invalid_syntax"
        end

        local count, countReason = readUnsigned(58, resolved.maxItems, "items_limit")
        if count == nil then
            return nil, countReason
        end
        if count > resolved.maxItems - itemCount then
            return nil, "items_limit"
        end

        if tag == "a" then
            local array = {}
            local index
            for index = 1, count do
                local child, childReason = parseValue(depth + 1, false)
                if childReason ~= nil then
                    return nil, childReason
                end
                array[index] = child
            end
            return array
        end

        -- Encoding an empty plain table always produces a0:.  Accepting m0:
        -- would create a value that cannot be re-encoded canonically.
        if count == 0 then
            return nil, "invalid_syntax"
        end
        local map = {}
        local previousKey = nil
        local seenKeys = {}
        local index
        for index = 1, count do
            if position > length then
                return nil, "truncated"
            end
            if string.sub(encoded, position, position) ~= "s" then
                return nil, "invalid_syntax"
            end
            position = position + 1
            local mapKey, keyReason = readStringBody()
            if mapKey == nil then
                return nil, keyReason
            end
            if seenKeys[mapKey] then
                return nil, "duplicate_key"
            end
            if previousKey ~= nil and compareByteStrings(previousKey, mapKey) >= 0 then
                return nil, "noncanonical_order"
            end
            seenKeys[mapKey] = true
            previousKey = mapKey

            local child, childReason = parseValue(depth + 1, false)
            if childReason ~= nil then
                return nil, childReason
            end
            map[mapKey] = child
        end
        return map
    end

    local result, reason = parseValue(0, true)
    if reason ~= nil then
        return nil, reason
    end
    if position <= length then
        return nil, "trailing_content"
    end
    return result
end

local function pathIndexSegment(index)
    return "i" .. integerString(index) .. ";"
end

local function pathKeySegment(key)
    return "k" .. integerString(#key) .. ":" .. key
end

function Serialization.flatten(value, limits)
    local resolved, limitReason = resolveLimits(limits)
    if resolved == nil then
        return nil, limitReason
    end

    local rows = {}
    local state = {
        active = {},
        bytes = 0,
        items = 0,
        seen = {}
    }

    local function addRow(path, valueType, rowValue)
        local cost = #path + #valueType + 2
        if valueType == "string" then
            cost = cost + #rowValue
        elseif valueType == "number" then
            cost = cost + #numberToken(rowValue)
        elseif valueType == "boolean" then
            cost = cost + 1
        elseif valueType == "array" or valueType == "map" then
            cost = cost + #integerString(rowValue)
        end
        if state.bytes + cost > resolved.maxEncodedBytes then
            return nil, "bytes_limit"
        end
        state.bytes = state.bytes + cost

        local row = { path = path, type = valueType }
        if valueType ~= "nil" then
            row.value = rowValue
        end
        rows[#rows + 1] = row
        return true
    end

    local flattenValue
    flattenValue = function(current, path, depth)
        if depth > resolved.maxDepth then
            return nil, "depth_limit"
        end
        state.items = state.items + 1
        if state.items > resolved.maxItems then
            return nil, "items_limit"
        end
        if #path > resolved.maxEncodedBytes then
            return nil, "bytes_limit"
        end

        local valueType = type(current)
        if valueType == "nil" then
            return addRow(path, "nil")
        elseif valueType == "boolean" then
            return addRow(path, "boolean", current)
        elseif valueType == "number" then
            local normalized, numberReason = validateNumber(current, resolved)
            if normalized == nil then
                return nil, numberReason
            end
            return addRow(path, "number", normalized)
        elseif valueType == "string" then
            if #current > resolved.maxStringBytes then
                return nil, "string_limit"
            end
            return addRow(path, "string", current)
        elseif valueType ~= "table" then
            return nil, "unsupported_type"
        end

        if state.seen[current] then
            if state.active[current] then
                return nil, "cycle"
            end
            return nil, "shared_reference"
        end
        state.seen[current] = true
        state.active[current] = true

        local remainingItems = resolved.maxItems - state.items
        local tableKind, count, tableReason = classifyTable(
            current,
            remainingItems,
            resolved.maxItems,
            resolved.maxStringBytes
        )
        if tableKind == nil then
            return nil, tableReason
        end
        local ok, reason = addRow(path, tableKind, count)
        if not ok then
            return nil, reason
        end

        if tableKind == "array" then
            local index
            for index = 1, count do
                ok, reason = flattenValue(
                    rawget(current, index),
                    path .. pathIndexSegment(index),
                    depth + 1
                )
                if not ok then
                    return nil, reason
                end
            end
        else
            local keys, keyReason = collectSortedKeys(
                current,
                remainingItems,
                resolved.maxStringBytes
            )
            if keys == nil then
                return nil, keyReason
            end
            local index
            for index = 1, #keys do
                local mapKey = keys[index]
                if type(mapKey) ~= "string" then
                    return nil, "invalid_table_key"
                end
                if #mapKey > resolved.maxStringBytes then
                    return nil, "string_limit"
                end
                ok, reason = flattenValue(
                    rawget(current, mapKey),
                    path .. pathKeySegment(mapKey),
                    depth + 1
                )
                if not ok then
                    return nil, reason
                end
            end
        end

        state.active[current] = nil
        return true
    end

    local ok, reason = flattenValue(value, "", 0)
    if not ok then
        return nil, reason
    end
    return rows
end

local ROW_TYPES = {
    ["nil"] = true,
    array = true,
    boolean = true,
    map = true,
    number = true,
    string = true
}

local function parsePath(path, limits)
    local position = 1
    local length = #path
    local segments = {}
    local parentPath = nil

    while position <= length do
        if #segments >= limits.maxDepth then
            return nil, nil, "depth_limit"
        end
        local segmentStart = position
        local tag = string.sub(path, position, position)
        position = position + 1

        if tag == "i" then
            local numberStart = position
            while position <= length and string.byte(path, position) ~= 59 do
                local byte = string.byte(path, position)
                if byte < 48 or byte > 57 then
                    return nil, nil, "invalid_path"
                end
                position = position + 1
            end
            if position > length then
                return nil, nil, "invalid_path"
            end
            local numberText = string.sub(path, numberStart, position - 1)
            local index, indexReason = parseCanonicalUnsigned(numberText, limits.maxItems)
            if index == nil or indexReason ~= nil or index < 1 then
                return nil, nil, "invalid_path"
            end
            position = position + 1
            segments[#segments + 1] = { kind = "index", value = index }
        elseif tag == "k" then
            local lengthStart = position
            while position <= length and string.byte(path, position) ~= 58 do
                local byte = string.byte(path, position)
                if byte < 48 or byte > 57 then
                    return nil, nil, "invalid_path"
                end
                position = position + 1
            end
            if position > length then
                return nil, nil, "invalid_path"
            end
            local lengthText = string.sub(path, lengthStart, position - 1)
            local keyLength, keyLengthReason = parseCanonicalUnsigned(
                lengthText,
                limits.maxStringBytes
            )
            if keyLength == nil or keyLengthReason ~= nil then
                return nil, nil, "invalid_path"
            end
            position = position + 1
            if length - position + 1 < keyLength then
                return nil, nil, "invalid_path"
            end
            local key = string.sub(path, position, position + keyLength - 1)
            position = position + keyLength
            segments[#segments + 1] = { kind = "key", value = key }
        else
            return nil, nil, "invalid_path"
        end

        parentPath = string.sub(path, 1, segmentStart - 1)
    end

    return segments, parentPath
end

local function denseRowCount(rows, maximumItems)
    if type(rows) ~= "table" or getmetatable(rows) ~= nil then
        return nil, "invalid_rows"
    end
    local count = 0
    local maximumIndex = 0
    local key
    for key in next, rows do
        if not isInteger(key) or key < 1 then
            return nil, "invalid_rows"
        end
        count = count + 1
        if key > maximumIndex then
            maximumIndex = key
        end
        if count > maximumItems or maximumIndex > maximumItems then
            return nil, "items_limit"
        end
    end
    if count == 0 or maximumIndex ~= count then
        return nil, "invalid_rows"
    end
    return count
end

local function validateRowShape(row, rowType)
    if type(row) ~= "table" or getmetatable(row) ~= nil then
        return nil, "invalid_row"
    end
    local key
    for key in next, row do
        if key ~= "path" and key ~= "type" and key ~= "value" then
            return nil, "invalid_row"
        end
    end
    if rowType == "nil" then
        if rawget(row, "value") ~= nil then
            return nil, "invalid_row"
        end
    elseif rawget(row, "value") == nil then
        return nil, "invalid_row"
    end
    return true
end

function Serialization.unflatten(rows, limits)
    local resolved, limitReason = resolveLimits(limits)
    if resolved == nil then
        return nil, limitReason
    end

    local rowCount, rowsReason = denseRowCount(rows, resolved.maxItems)
    if rowCount == nil then
        return nil, rowsReason
    end

    local nodes = {}
    local byteCount = 0
    local index
    for index = 1, rowCount do
        local row = rawget(rows, index)
        local path = type(row) == "table" and rawget(row, "path") or nil
        local rowType = type(row) == "table" and rawget(row, "type") or nil
        if type(path) ~= "string" or type(rowType) ~= "string" or not ROW_TYPES[rowType] then
            return nil, "invalid_row"
        end
        if #path > resolved.maxEncodedBytes then
            return nil, "bytes_limit"
        end
        local shapeOk, shapeReason = validateRowShape(row, rowType)
        if not shapeOk then
            return nil, shapeReason
        end
        if nodes[path] ~= nil then
            return nil, "duplicate_path"
        end

        local segments, parentPath, pathReason = parsePath(path, resolved)
        if segments == nil then
            return nil, pathReason
        end

        local rowValue = rawget(row, "value")
        local valueCost = 0
        if rowType == "boolean" then
            if type(rowValue) ~= "boolean" then
                return nil, "invalid_row"
            end
            valueCost = 1
        elseif rowType == "number" then
            local normalized, numberReason = validateNumber(rowValue, resolved)
            if normalized == nil then
                return nil, numberReason
            end
            rowValue = normalized
            valueCost = #numberToken(rowValue)
        elseif rowType == "string" then
            if type(rowValue) ~= "string" then
                return nil, "invalid_row"
            end
            if #rowValue > resolved.maxStringBytes then
                return nil, "string_limit"
            end
            valueCost = #rowValue
        elseif rowType == "array" or rowType == "map" then
            if not isInteger(rowValue)
                or rowValue < 0
                or rowValue > resolved.maxItems
                or (rowType == "map" and rowValue == 0) then
                return nil, "invalid_row"
            end
            valueCost = #integerString(rowValue)
        end

        byteCount = byteCount + #path + #rowType + valueCost + 2
        if byteCount > resolved.maxEncodedBytes then
            return nil, "bytes_limit"
        end

        nodes[path] = {
            childCount = 0,
            children = {},
            parentPath = parentPath,
            path = path,
            segments = segments,
            type = rowType,
            value = rowValue
        }
    end

    local root = nodes[""]
    if root == nil then
        return nil, "missing_root"
    end

    local path, node
    for path, node in next, nodes do
        if path ~= "" then
            if node.type == "nil" then
                return nil, "invalid_row"
            end
            local parent = nodes[node.parentPath]
            if parent == nil then
                return nil, "missing_parent"
            end
            local segment = node.segments[#node.segments]
            if segment.kind == "index" then
                if parent.type ~= "array" or segment.value > parent.value then
                    return nil, "invalid_path"
                end
                if parent.children[segment.value] ~= nil then
                    return nil, "duplicate_path"
                end
                parent.children[segment.value] = node
            else
                if parent.type ~= "map" then
                    return nil, "invalid_path"
                end
                if parent.children[segment.value] ~= nil then
                    return nil, "duplicate_path"
                end
                parent.children[segment.value] = node
            end
            parent.childCount = parent.childCount + 1
        end
    end

    for path, node in next, nodes do
        if node.type == "array" then
            if node.childCount ~= node.value then
                return nil, "child_count"
            end
            for index = 1, node.value do
                if node.children[index] == nil then
                    return nil, "child_count"
                end
            end
        elseif node.type == "map" then
            if node.childCount ~= node.value then
                return nil, "child_count"
            end
        elseif node.childCount ~= 0 then
            return nil, "invalid_path"
        end
    end

    local build
    build = function(current)
        if current.type == "nil" then
            return nil
        elseif current.type == "boolean"
            or current.type == "number"
            or current.type == "string" then
            return current.value
        elseif current.type == "array" then
            local result = {}
            local childIndex
            for childIndex = 1, current.value do
                result[childIndex] = build(current.children[childIndex])
            end
            return result
        end

        local result = {}
        local keys = {}
        local key
        for key in next, current.children do
            keys[#keys + 1] = key
        end
        table.sort(keys, byteStringLess)
        local keyIndex
        for keyIndex = 1, #keys do
            key = keys[keyIndex]
            result[key] = build(current.children[key])
        end
        return result
    end

    return build(root)
end

function Serialization.equal(left, right)
    local state = {
        items = 0,
        seenLeft = {},
        seenRight = {}
    }

    local compare
    compare = function(leftValue, rightValue, depth)
        if depth > HARD_LIMITS.maxDepth then
            return false
        end
        state.items = state.items + 1
        if state.items > HARD_LIMITS.maxItems then
            return false
        end

        local leftType = type(leftValue)
        if leftType ~= type(rightValue) then
            return false
        end
        if leftType == "nil" then
            return true
        elseif leftType == "boolean" then
            return leftValue == rightValue
        elseif leftType == "string" then
            -- equal has no limits argument, so values outside the module's
            -- default neutral-string budget are not comparable neutral data.
            return #leftValue <= DEFAULT_LIMITS.maxStringBytes
                and #rightValue <= DEFAULT_LIMITS.maxStringBytes
                and leftValue == rightValue
        elseif leftType == "number" then
            return isFinite(leftValue) and isFinite(rightValue) and leftValue == rightValue
        elseif leftType ~= "table" then
            return false
        end

        if state.seenLeft[leftValue] or state.seenRight[rightValue] then
            return false
        end
        state.seenLeft[leftValue] = true
        state.seenRight[rightValue] = true

        local remainingItems = HARD_LIMITS.maxItems - state.items
        local leftKind, leftCount = classifyTable(
            leftValue,
            remainingItems,
            HARD_LIMITS.maxItems,
            DEFAULT_LIMITS.maxStringBytes
        )
        local rightKind, rightCount = classifyTable(
            rightValue,
            remainingItems,
            HARD_LIMITS.maxItems,
            DEFAULT_LIMITS.maxStringBytes
        )
        if leftKind == nil
            or rightKind == nil
            or leftKind ~= rightKind
            or leftCount ~= rightCount then
            return false
        end

        if leftKind == "array" then
            local index
            for index = 1, leftCount do
                if not compare(rawget(leftValue, index), rawget(rightValue, index), depth + 1) then
                    return false
                end
            end
            return true
        end

        local leftKeys = collectSortedKeys(
            leftValue,
            remainingItems,
            DEFAULT_LIMITS.maxStringBytes
        )
        local rightKeys = collectSortedKeys(
            rightValue,
            remainingItems,
            DEFAULT_LIMITS.maxStringBytes
        )
        if leftKeys == nil or rightKeys == nil then
            return false
        end
        local index
        for index = 1, #leftKeys do
            if leftKeys[index] ~= rightKeys[index] then
                return false
            end
            if not compare(
                rawget(leftValue, leftKeys[index]),
                rawget(rightValue, rightKeys[index]),
                depth + 1
            ) then
                return false
            end
        end
        return true
    end

    return compare(left, right, 0)
end

FieldProfitabilityLedger.Core.Serialization = Serialization

return Serialization
